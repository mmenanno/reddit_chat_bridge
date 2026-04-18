# frozen_string_literal: true

require "securerandom"
require "discord/poster"

module Discord
  # Handles a single Discord MESSAGE_CREATE event by relaying it to the
  # matching Matrix room. Injected into Discord::Gateway; the gateway
  # calls `dispatch(message)` for each message in a bridged channel.
  #
  # Rules:
  #   - Only messages authored by the operator's Discord user (or the
  #     configured allow-list) get relayed. Echoes of bot-posted messages
  #     are ignored.
  #   - txn_id: a random UUID. Matrix requires it for idempotency; we
  #     cache it on OutboundMessage so a retry uses the same txn_id and
  #     Matrix dedupes server-side.
  #   - On success, the Matrix event_id is registered in SentRegistry
  #     (via OutboundMessage.register_sent!) so the subsequent /sync
  #     echo is filtered in the Poster.
  #   - If a Discord client + channel index are injected, the operator's
  #     original Discord message is replaced with a webhook repost under
  #     the operator's Reddit identity so the `#dm-*` channel reads
  #     uniformly — every bubble looks like it came from a Reddit user.
  class OutboundDispatcher
    OWN_NAME_SUFFIX = Poster::OWN_NAME_SUFFIX
    OWN_DISPLAY_NAME_KEY = "own_display_name"
    OWN_AVATAR_URL_KEY = "own_avatar_url"

    def initialize(
      matrix_client:,
      discord_client: nil,
      channel_index: nil,
      media_resolver: nil,
      reddit_profile_client: nil,
      operator_discord_ids: [],
      journal: nil
    )
      @matrix_client = matrix_client
      @discord_client = discord_client
      @channel_index = channel_index
      @media_resolver = media_resolver
      @reddit_profile_client = reddit_profile_client
      @operator_discord_ids = operator_discord_ids.map(&:to_s).reject(&:empty?).to_set
      @journal = journal
    end

    def dispatch(message)
      return unless relayable?(message)

      room = Room.find_by(discord_channel_id: message.fetch("channel_id").to_s)
      return unless room

      txn_id = SecureRandom.uuid
      discord_id = message["id"].to_s
      body = message["content"].to_s
      return if body.empty?

      event_id = @matrix_client.send_message(room_id: room.matrix_room_id, body: body, txn_id: txn_id)
      OutboundMessage.register_sent!(
        txn_id: txn_id,
        discord_message_id: discord_id,
        matrix_room_id: room.matrix_room_id,
        matrix_event_id: event_id,
      )
      room.advance_event!(event_id)
      replace_with_reddit_persona!(message, room, body)
      @journal&.info(
        "Discord → Reddit: relayed message #{discord_id} as Matrix event #{event_id}",
        source: "outbound",
      )
    rescue Matrix::Error => e
      OutboundMessage.register_failure!(
        txn_id: txn_id,
        discord_message_id: message["id"].to_s,
        matrix_room_id: room&.matrix_room_id.to_s,
        error: "#{e.class}: #{e.message}",
      )
      @journal&.warn("Discord → Reddit relay failed: #{e.class}: #{e.message}", source: "outbound")
    end

    private

    # Replaces the operator's raw Discord message (their Discord avatar +
    # display name) with a webhook repost under their Reddit identity so
    # the channel stays visually uniform. Post-then-delete ordering — a
    # failed delete leaves a duplicate (annoying, not lost), while a
    # failed post-before-delete would erase the message outright.
    def replace_with_reddit_persona!(message, room, body)
      return unless @discord_client && @channel_index

      webhook_id, webhook_token = @channel_index.ensure_webhook(room: room.reload)
      @discord_client.execute_webhook(
        webhook_id: webhook_id,
        webhook_token: webhook_token,
        payload: webhook_payload(body),
      )
      @discord_client.delete_message(
        channel_id: message.fetch("channel_id"),
        message_id: message.fetch("id"),
      )
    rescue Discord::Error => e
      @journal&.warn(
        "Discord persona rewrite failed: #{e.class}: #{e.message}",
        source: "outbound",
      )
    end

    def webhook_payload(body)
      identity = own_identity
      payload = { content: body, username: "#{identity[:name]}#{OWN_NAME_SUFFIX}" }
      payload[:avatar_url] = identity[:avatar] if identity[:avatar].present?
      payload
    end

    # Cached per-process. A restart refreshes; the web UI's /auth flow
    # can also clear the AppConfig rows manually if Reddit's display
    # name or avatar changes and the operator wants a faster refresh.
    def own_identity
      @own_identity ||= resolve_own_identity
    end

    def resolve_own_identity
      name = AppConfig.fetch(OWN_DISPLAY_NAME_KEY, "")
      avatar = AppConfig.fetch(OWN_AVATAR_URL_KEY, "")

      name, avatar = fill_from_matrix_profile(name, avatar) if name.empty? || avatar.empty?
      avatar = fill_from_reddit_profile(name) if avatar.empty? && name.present?
      name = matrix_id_localpart(AppConfig.fetch("matrix_user_id", "")) if name.empty?

      persist_identity(name, avatar)
      { name: name, avatar: avatar.presence }
    end

    def fill_from_matrix_profile(name, avatar)
      user_id = AppConfig.fetch("matrix_user_id", "")
      return [name, avatar] if user_id.empty?

      profile = fetch_profile_safely(user_id)
      return [name, avatar] unless profile.is_a?(Hash)

      name = profile["displayname"].to_s if name.empty?
      if avatar.empty?
        mxc = profile["avatar_url"].to_s
        resolved = @media_resolver&.resolve(mxc) if mxc.start_with?("mxc://")
        avatar = resolved if resolved
      end
      [name, avatar]
    end

    def fill_from_reddit_profile(name)
      return "" unless @reddit_profile_client

      @reddit_profile_client.fetch_avatar_url(name).to_s
    end

    def persist_identity(name, avatar)
      AppConfig.set(OWN_DISPLAY_NAME_KEY, name) if name.present? && AppConfig.fetch(OWN_DISPLAY_NAME_KEY, "") != name
      AppConfig.set(OWN_AVATAR_URL_KEY, avatar) if avatar.present? && AppConfig.fetch(OWN_AVATAR_URL_KEY, "") != avatar
    end

    def fetch_profile_safely(user_id)
      @matrix_client.profile(user_id: user_id)
    rescue Matrix::Error
      nil
    end

    def matrix_id_localpart(matrix_id)
      matrix_id.to_s.sub(/\A@/, "").sub(/:.+\z/, "")
    end

    # Accept only messages from the configured operator(s), and only when
    # Discord's own flags say it's a human-typed DEFAULT/REPLY message.
    # Bots are ignored to close the "our own bot message" loop before we
    # even hit SentRegistry.
    def relayable?(message)
      return false if message["author"].is_a?(Hash) && message["author"]["bot"]
      return false unless [nil, 0, 19].include?(message["type"]) # DEFAULT (0) or REPLY (19); nil for older payloads

      author_id = message.dig("author", "id").to_s
      return false if author_id.empty?
      return false unless @operator_discord_ids.empty? || @operator_discord_ids.include?(author_id)

      true
    end
  end
end
