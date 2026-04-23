# frozen_string_literal: true

require "matrix/id"

module Discord
  # Matrix → Discord dispatcher. Plugged into `Matrix::SyncLoop` as the
  # `dispatcher:` argument; each batch of NormalizedEvents flows through
  # here on its way to Discord.
  #
  # Per event:
  #   1. Short-circuit if already recorded in PostedEvent (checkpoint rewind).
  #   2. Upsert Room; refresh counterparty info, falling back to a Matrix
  #      /profile lookup when /sync didn't ship lazy-loaded member state.
  #   3. Rename an existing channel when the counterparty username resolves
  #      later than the channel's creation — so early "dm-t2_opaque" channels
  #      self-heal the first time the real username becomes known.
  #   4. Post through the channel's webhook with a per-message username +
  #      avatar_url override so each message looks like it came from the
  #      real Reddit user, not from the bot. Recover from a deleted
  #      webhook or channel by clearing the stale ids and retrying.
  #   5. Truncate content to Discord's 2000-char cap; skip (but still record)
  #      on 400 — bad content isn't retryable, looping makes it worse.
  class Poster
    OWN_NAME_SUFFIX    = " \u{1F4E4}" # 📤 — disambiguates bridged-from-Reddit from native Discord.
    SYSTEM_NAME        = "Reddit"

    DISCORD_MESSAGE_CAP = 2000
    TRUNCATION_NOTICE   = "\n…[truncated]"
    TRUNCATION_HEADROOM = DISCORD_MESSAGE_CAP - TRUNCATION_NOTICE.length

    RATE_LIMIT_MAX_ATTEMPTS   = 3
    RATE_LIMIT_FALLBACK_SLEEP = 1.0

    # AppConfig flag set whenever we 403 on a webhook op; the dashboard
    # reads this to show an actionable "enable Manage Webhooks" banner.
    PERMISSIONS_FLAG_KEY = "discord_permissions_blocked_at"

    # Re-check Reddit's profile API at most once every 24h after a miss.
    AVATAR_NEGATIVE_CACHE_TTL = 24 * 3600

    def initialize(client:, channel_index:, matrix_client: nil, logger: nil, sent_registry: nil, reddit_profile_client: nil, channel_reorderer: nil, sleeper: Kernel.method(:sleep))
      @client = client
      @channel_index = channel_index
      @matrix_client = matrix_client
      @logger = logger
      @sent_registry = sent_registry
      @reddit_profile_client = reddit_profile_client
      @channel_reorderer = channel_reorderer
      @sleeper = sleeper
      # nil = unknown; checked lazily on first successful post, then tracked
      # in-process so the common hot path skips a per-event AppConfig read.
      @permissions_flag_set = nil
    end

    def call(events)
      @auth_warned_this_batch = false
      @activity_posted = false
      events.each { |event| post_one(event) }
      @channel_reorderer&.reorder! if @activity_posted
    end

    private

    def post_one(event)
      return if PostedEvent.posted?(event.event_id)
      return if echo_of_our_send?(event)
      return if terminated_room?(event.room_id)

      room = Room.find_or_create_by_matrix_id!(event.room_id)
      auto_unarchive!(room)
      refresh_counterparty_and_channel!(room, event)
      send_with_recovery(room, event)
      clear_permissions_flag!
      PostedEvent.record!(event_id: event.event_id, room_id: event.room_id)
      room.advance_event!(event.event_id)
      room.mark_activity!(time: activity_time_for(event))
      @activity_posted = true
    rescue Discord::BadRequest => e
      # Unrecoverable request-shape error. Record anyway so we don't loop.
      @logger&.warn("Discord rejected event #{event.event_id} (400): #{e.message}")
      PostedEvent.record!(event_id: event.event_id, room_id: event.room_id)
      room&.advance_event!(event.event_id)
    rescue Discord::AuthError => e
      # Almost always "Missing Permissions" — the bot role lacks Manage
      # Webhooks. Recording as posted prevents the sync loop from hammering
      # the same event every tick; after the operator fixes the role,
      # clicking "Rebuild all rooms" on /actions backfills from /messages.
      mark_permissions_blocked!(e)
      PostedEvent.record!(event_id: event.event_id, room_id: event.room_id)
      room&.advance_event!(event.event_id)
    end

    # When the operator types in Discord, we relay that to Reddit and record
    # the returned Matrix event_id in SentRegistry. /sync later ships back
    # the same event to us — skipping here prevents a double-post back into
    # Discord. PostedEvent still records it so a future rewind stays idempotent.
    def echo_of_our_send?(event)
      return false unless @sent_registry
      return false unless event.own?

      if @sent_registry.sent_by_us?(event.event_id)
        PostedEvent.record!(event_id: event.event_id, room_id: event.room_id)
        true
      else
        false
      end
    end

    # Keeps the Room's counterparty metadata current, fetches the peer's
    # Matrix profile when needed, and syncs the Discord channel's slug +
    # topic if either would change as a result. The topic carries direct
    # Reddit profile + chat URLs so it needs to re-push on a deletion flip
    # even when the slug stays put.
    def refresh_counterparty_and_channel!(room, event)
      return if event.own? || event.system?
      return if event.sender.blank?

      # Resolution order — cheapest first:
      #   1. Per-event sender_username (lazy-loaded member state from /sync)
      #   2. Room's cached counterparty_username when this event is from the
      #      counterparty we've already resolved — avoids a /profile call on
      #      every subsequent message in the same DM (the common case)
      #   3. Live Matrix /profile lookup as a last resort
      username = event.sender_username.presence ||
        cached_counterparty_username(room, event.sender) ||
        fetch_username_from_matrix(event.sender)

      old_slug = @channel_index.channel_name_for(room)
      old_topic = @channel_index.topic_for(room)
      changes = room.ensure_counterparty!(matrix_id: event.sender, username: username)

      return unless room.discord_channel_id
      return unless changes[:counterparty_username] || changes.key?(:counterparty_deleted_at)

      new_slug = @channel_index.channel_name_for(room)
      new_topic = @channel_index.topic_for(room)
      return if new_slug == old_slug && new_topic == old_topic

      sync_channel_metadata!(
        channel_id: room.discord_channel_id,
        name: new_slug == old_slug ? nil : new_slug,
        topic: new_topic == old_topic ? nil : new_topic,
      )
    end

    def cached_counterparty_username(room, sender_id)
      return unless sender_id == room.counterparty_matrix_id

      room.counterparty_username.presence
    end

    def fetch_username_from_matrix(user_id)
      return unless @matrix_client

      profile = @matrix_client.profile(user_id: user_id)
      profile.is_a?(Hash) ? profile["displayname"] : nil
    rescue Matrix::Error => e
      @logger&.warn("Matrix profile lookup failed for #{user_id}: #{e.message}")
      nil
    end

    def sync_channel_metadata!(channel_id:, name:, topic:)
      @client.update_channel(channel_id: channel_id, name: name, topic: topic)
    rescue Discord::Error => e
      @logger&.warn(
        "channel metadata update #{channel_id} (name=#{name.inspect} topic=#{topic && "(set)"}) failed: #{e.message}",
      )
    end

    # Webhook delivery with two distinct recovery paths:
    #   - webhook 404: the hook itself was deleted but the channel may still
    #     exist. Clear the webhook id/token and re-ensure — ChannelIndex will
    #     create a new webhook on the same channel.
    #   - webhook 404 after re-ensure: the underlying channel is also gone.
    #     ChannelIndex.ensure_webhook already cleared discord_channel_id in
    #     that case, so re-ensuring now creates both channel and webhook.
    def send_with_recovery(room, event)
      execute_through_webhook(room, event)
    rescue Discord::NotFound
      room.clear_webhook!
      execute_through_webhook(room, event)
    end

    def execute_through_webhook(room, event)
      id, token = @channel_index.ensure_webhook(room: room)
      send_with_rate_limit_retry(
        webhook_id: id,
        webhook_token: token,
        payload: build_payload(event, room),
      )
    end

    def send_with_rate_limit_retry(webhook_id:, webhook_token:, payload:)
      attempt = 0
      begin
        attempt += 1
        @client.execute_webhook(webhook_id: webhook_id, webhook_token: webhook_token, payload: payload)
      rescue Discord::RateLimited => e
        raise if attempt >= RATE_LIMIT_MAX_ATTEMPTS

        sleep_seconds = e.retry_after_ms.to_f.positive? ? (e.retry_after_ms / 1000.0) : RATE_LIMIT_FALLBACK_SLEEP
        @sleeper.call(sleep_seconds)
        retry
      end
    end

    def build_payload(event, room)
      payload = { content: format_content(event) }
      payload[:username] = username_for(event, room)
      avatar = resolve_avatar_url(event, room)
      payload[:avatar_url] = avatar if avatar.present?
      payload
    end

    # Avatar resolution is tiered:
    #   1. Matrix member state (event.sender_avatar_url) — authoritative
    #      when Reddit chat has one. Cached on the Room so later events
    #      without carrying state can use the same URL.
    #   2. For OWN events: operator's avatar from AppConfig (populated by
    #      OutboundDispatcher). Skips the counterparty branch entirely —
    #      the room-level avatar cache holds the OTHER person's face,
    #      which must never stand in for the operator.
    #   3. For peer events: room's cached counterparty avatar, then
    #      Reddit public profile (`/user/<name>/about.json`) — one fetch
    #      per user per 24h (negative cache prevents hammering on
    #      deleted users).
    def resolve_avatar_url(event, room)
      if event.sender_avatar_url.present?
        room.cache_avatar_url!(event.sender_avatar_url) unless event.own? || event.system?
        return event.sender_avatar_url
      end

      return own_avatar_url if event.own?
      return if event.system?
      return room.counterparty_avatar_url if room.counterparty_avatar_url.present?
      return if room.counterparty_username.blank?
      return unless @reddit_profile_client
      return if recent_avatar_miss?(room)

      url = @reddit_profile_client.fetch_avatar_url(room.counterparty_username)
      if url.present?
        room.cache_avatar_url!(url)
        url
      else
        room.record_avatar_lookup_miss!
        nil
      end
    end

    def recent_avatar_miss?(room)
      ts = room.counterparty_avatar_checked_at
      return false unless ts

      Time.current - ts < AVATAR_NEGATIVE_CACHE_TTL
    end

    def format_content(event)
      pieces = [body_for(event)]
      pieces << event.media_url if event.media?
      raw = pieces.compact.reject(&:empty?).join("\n")
      return raw if raw.length <= DISCORD_MESSAGE_CAP

      raw[0, TRUNCATION_HEADROOM] + TRUNCATION_NOTICE
    end

    # Reddit's image events typically ship with content.body set to the raw
    # filename (e.g. "image.jpg") — useless context inside a DM. Prefer a
    # human-readable hint when the body is just the attachment name.
    def body_for(event)
      return event.body unless event.media?
      return event.body if event.body.to_s.include?(" ") # actual sentence

      "📎 #{event.body}"
    end

    def username_for(event, room)
      return SYSTEM_NAME if event.system?

      base = display_name_for(event, room)
      base += OWN_NAME_SUFFIX if event.own?
      base
    end

    # Order of preference for a sender's display name:
    #   1. The username Matrix shipped with this event (may be blank on
    #      resume syncs or backfill where member state wasn't lazy-loaded).
    #   2. For OWN events: the operator's Reddit handle from AppConfig.
    #      Critical for the backfill path — historical events are replayed
    #      through the Poster (not OutboundDispatcher) and frequently arrive
    #      without sender_username, so without this the operator's own
    #      bubbles would render as their `t2_<id>` Matrix localpart.
    #   3. The room's stored counterparty_username — `refresh_counterparty_
    #      and_channel!` just populated this from /profile if the event
    #      didn't carry it, so by the time we're formatting the prefix it's
    #      the authoritative name.
    #   4. The matrix_id localpart (e.g. `t2_abc123`) as a last resort so
    #      we never post an empty username.
    def display_name_for(event, room)
      return event.sender_username if event.sender_username.present?

      if event.own?
        cached = own_display_name
        return cached if cached.present?
      end

      return room.counterparty_username if event.sender == room.counterparty_matrix_id && room.counterparty_username.present?

      Matrix::Id.localpart(event.sender)
    end

    # Operator's Reddit handle as stored in AppConfig by OutboundDispatcher.
    # A stored value matching the Matrix localpart means the dispatcher
    # failed to resolve a real handle — treat as absent so the caller falls
    # back and the localpart pass-through happens in exactly one place.
    def own_display_name
      return @own_display_name if defined?(@own_display_name)

      stored = AppConfig.fetch("own_display_name", "").to_s
      @own_display_name = stored.present? && stored != own_localpart ? stored : nil
    end

    def own_avatar_url
      return @own_avatar_url if defined?(@own_avatar_url)

      stored = AppConfig.fetch("own_avatar_url", "").to_s
      @own_avatar_url = stored.presence
    end

    def own_localpart
      @own_localpart ||= Matrix::Id.localpart(AuthState.user_id.to_s)
    end

    # Matrix's origin_server_ts is unix millis. Fall back to now when
    # the event didn't carry one (shouldn't happen, but defensively).
    def activity_time_for(event)
      ts = event.origin_server_ts
      return Time.current unless ts.is_a?(Integer) || ts.is_a?(Numeric)

      Time.at(ts.to_f / 1000.0).utc
    end

    # Terminated ("hidden") rooms never auto-recover — events for them
    # get silently dropped until the operator clicks Restore on /rooms.
    # Reddit's Matrix server refuses Matrix /leave on DM rooms, so
    # local filtering is the only way to make End chat stick.
    def terminated_room?(matrix_room_id)
      Room.terminated.exists?(matrix_room_id: matrix_room_id)
    end

    # New activity on an archived room flips it back to active. The channel
    # was deleted on archive so ensure_channel will mint a fresh one; the
    # empty channel is intentional — the admin can click "Restore history"
    # on /rooms to backfill if they want the old messages back.
    def auto_unarchive!(room)
      return unless room.archived?

      room.unarchive!
      @logger&.info("Room #{room.matrix_room_id} unarchived - new activity from counterparty.")
    end

    def mark_permissions_blocked!(error)
      AppConfig.set(PERMISSIONS_FLAG_KEY, Time.current.utc.iso8601)
      @permissions_flag_set = true
      return if @auth_warned_this_batch

      @auth_warned_this_batch = true
      @logger&.warn(
        "Discord rejected webhook post: #{error.message}. " \
        "Enable 'Manage Webhooks' on the bot role, then click 'Rebuild all rooms' on /actions.",
      )
    end

    def clear_permissions_flag!
      @permissions_flag_set = !AppConfig.fetch(PERMISSIONS_FLAG_KEY, "").empty? if @permissions_flag_set.nil?
      return unless @permissions_flag_set

      AppConfig.set(PERMISSIONS_FLAG_KEY, "")
      @permissions_flag_set = false
    end
  end
end
