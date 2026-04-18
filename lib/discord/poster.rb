# frozen_string_literal: true

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
  #   4. Post via Discord, retrying on rate limits and rebuilding the channel
  #      on 404 (operator manually deleted it).
  #   5. Truncate content to Discord's 2000-char cap; skip (but still record)
  #      on 400 — bad content isn't retryable, looping makes it worse.
  class Poster
    OWN_PREFIX    = "📤 **You**"
    SYSTEM_PREFIX = "🤖 **Reddit**"

    DISCORD_MESSAGE_CAP = 2000
    TRUNCATION_NOTICE   = "\n…[truncated]"
    TRUNCATION_HEADROOM = DISCORD_MESSAGE_CAP - TRUNCATION_NOTICE.length

    RATE_LIMIT_MAX_ATTEMPTS   = 3
    RATE_LIMIT_FALLBACK_SLEEP = 1.0

    def initialize(client:, channel_index:, matrix_client: nil, logger: nil, sleeper: Kernel.method(:sleep))
      @client = client
      @channel_index = channel_index
      @matrix_client = matrix_client
      @logger = logger
      @sleeper = sleeper
    end

    def call(events)
      events.each { |event| post_one(event) }
    end

    private

    def post_one(event)
      return if PostedEvent.posted?(event.event_id)

      room = Room.find_or_create_by_matrix_id!(event.room_id)
      refresh_counterparty_and_channel!(room, event)
      send_with_channel_recovery(room, event)
      PostedEvent.record!(event_id: event.event_id, room_id: event.room_id)
      room.advance_event!(event.event_id)
    rescue Discord::BadRequest => e
      # Unrecoverable request-shape error. Record anyway so we don't loop.
      @logger&.warn("Discord rejected event #{event.event_id} (400): #{e.message}")
      PostedEvent.record!(event_id: event.event_id, room_id: event.room_id)
      room&.advance_event!(event.event_id)
    end

    # Keeps the Room's counterparty metadata current, fetches the peer's
    # Matrix profile when needed, and renames the Discord channel if the
    # slug would change as a result.
    def refresh_counterparty_and_channel!(room, event)
      return if event.own? || event.system?
      return if event.sender.blank?

      username = event.sender_username.presence || fetch_username_from_matrix(event.sender)

      old_slug = @channel_index.channel_name_for(room)
      changes = room.ensure_counterparty!(matrix_id: event.sender, username: username)

      # If the name changed and a channel already exists, rename it to match.
      return unless changes[:counterparty_username] && room.discord_channel_id

      new_slug = @channel_index.channel_name_for(room.reload)
      return if new_slug == old_slug

      rename_channel!(room.discord_channel_id, new_slug)
    end

    def fetch_username_from_matrix(user_id)
      return unless @matrix_client

      profile = @matrix_client.profile(user_id: user_id)
      profile.is_a?(Hash) ? profile["displayname"] : nil
    rescue Matrix::Error => e
      @logger&.warn("Matrix profile lookup failed for #{user_id}: #{e.message}")
      nil
    end

    def rename_channel!(channel_id, new_name)
      @client.rename_channel(channel_id: channel_id, name: new_name)
    rescue Discord::Error => e
      @logger&.warn("channel rename #{channel_id} → #{new_name} failed: #{e.message}")
    end

    def send_with_channel_recovery(room, event)
      channel_id = @channel_index.ensure_channel(room: room)
      send_with_rate_limit_retry(channel_id: channel_id, content: format_content(event, room))
    rescue Discord::NotFound
      # Operator deleted the channel; forget the stale id and let
      # ChannelIndex create a fresh one on the retry.
      room.update!(discord_channel_id: nil)
      channel_id = @channel_index.ensure_channel(room: room.reload)
      send_with_rate_limit_retry(channel_id: channel_id, content: format_content(event, room))
    end

    def send_with_rate_limit_retry(channel_id:, content:)
      attempt = 0
      begin
        attempt += 1
        @client.send_message(channel_id: channel_id, content: content)
      rescue Discord::RateLimited => e
        raise if attempt >= RATE_LIMIT_MAX_ATTEMPTS

        sleep_seconds = e.retry_after_ms.to_f.positive? ? (e.retry_after_ms / 1000.0) : RATE_LIMIT_FALLBACK_SLEEP
        @sleeper.call(sleep_seconds)
        retry
      end
    end

    def format_content(event, room)
      pieces = [prefix_for(event, room), body_for(event)]
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

    def prefix_for(event, room)
      return OWN_PREFIX if event.own?
      return SYSTEM_PREFIX if event.system?

      "**#{display_name_for(event, room)}**"
    end

    # Order of preference for the counterparty's display name:
    #   1. The username Matrix shipped with this event (may be blank on
    #      resume syncs where member state wasn't lazy-loaded).
    #   2. The room's stored counterparty_username — `refresh_counterparty_
    #      and_channel!` just populated this from /profile if the event
    #      didn't carry it, so by the time we're formatting the prefix it's
    #      the authoritative name.
    #   3. The matrix_id localpart (e.g. `t2_abc123`) as a last resort so
    #      we never post an empty `**` prefix.
    def display_name_for(event, room)
      return event.sender_username if event.sender_username.present?

      return room.counterparty_username if event.sender == room.counterparty_matrix_id && room.counterparty_username.present?

      matrix_id_localpart(event.sender)
    end

    def matrix_id_localpart(matrix_id)
      matrix_id.to_s.sub(/\A@/, "").sub(/:.+\z/, "")
    end

    def record_counterparty(room, event)
      return if event.own? || event.system?
      return if event.sender.blank?

      room.ensure_counterparty!(matrix_id: event.sender, username: event.sender_username.presence)
    end
  end
end
