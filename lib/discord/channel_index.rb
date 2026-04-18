# frozen_string_literal: true

module Discord
  # Given a Room, returns the Discord channel id — creating `#dm-<username>`
  # under the configured category on first call. Idempotent: once the Room
  # has a `discord_channel_id`, subsequent calls short-circuit.
  #
  # Channel names are sanitized to Discord's rules (lowercase, ASCII, no
  # spaces, dashes instead of anything else) and always prefixed `dm-` so
  # future group-chat support can use a different prefix without collision.
  class ChannelIndex
    CHANNEL_PREFIX = "dm-"
    CHANNEL_NAME_MAX = 90 # leaves headroom under Discord's 100-char limit
    CHANNEL_TOPIC_MAX = 1024 # Discord's documented topic cap
    WEBHOOK_NAME = "Reddit Chat Bridge"

    def initialize(client:, guild_id:, category_id:)
      @client = client
      @guild_id = guild_id
      @category_id = category_id
    end

    def ensure_channel(room:)
      return room.discord_channel_id if room.discord_channel_id

      name = channel_name_for(room)
      channel_id = @client.create_channel(
        guild_id: @guild_id,
        name: name,
        parent_id: @category_id,
        topic: topic_for(room),
      )
      room.attach_discord_channel!(channel_id)
      channel_id
    end

    # Returns the [id, token] pair for the room's webhook, creating one on the
    # room's Discord channel if none is cached. If the underlying channel was
    # deleted, Discord returns 404 on create — we clear the stale channel id
    # and let the caller retry through ensure_channel.
    def ensure_webhook(room:)
      cached = webhook_pair(room)
      return cached if cached

      channel_id = ensure_channel(room: room)
      hook = @client.create_webhook(channel_id: channel_id, name: WEBHOOK_NAME)
      room.attach_webhook!(id: hook.fetch("id"), token: hook.fetch("token"))
      [hook.fetch("id"), hook.fetch("token")]
    rescue Discord::NotFound
      # The stored discord_channel_id is gone; clear it and let the next
      # ensure_channel call recreate the channel + webhook from scratch.
      room.update!(discord_channel_id: nil)
      raise
    end

    def webhook_pair(room)
      return unless room.discord_webhook_id && room.discord_webhook_token

      [room.discord_webhook_id, room.discord_webhook_token]
    end

    # Public so Poster can compare the slug before and after a counterparty
    # update and decide whether to rename an existing Discord channel.
    def channel_name_for(room)
      slug = slug_source(room)
      "#{CHANNEL_PREFIX}#{sanitize(slug)}"[0, CHANNEL_NAME_MAX]
    end

    # Channel topic surfacing the direct Reddit links — helpful because
    # the Discord channel is the operator's primary view of the chat, and
    # a click-through to the original profile / conversation sidesteps
    # our own transcript UI entirely. Returns nil while the counterparty
    # username is still unresolved; Poster/Reconciler will backfill the
    # topic via `update_channel` once the name lands.
    def topic_for(room)
      username = room.counterparty_username.to_s
      return if username.empty?

      lines = ["Reddit DM with u/#{username}"]
      lines << if room.counterparty_deleted?
        "Reddit account deleted"
      else
        "Profile: https://www.reddit.com/user/#{username}"
      end
      lines << "Chat: https://chat.reddit.com/user/#{username}"
      lines.join("\n")[0, CHANNEL_TOPIC_MAX]
    end

    def slug_source(room)
      return room.counterparty_username if room.counterparty_username.present?
      return matrix_id_to_slug(room.counterparty_matrix_id) if room.counterparty_matrix_id.present?

      matrix_id_to_slug(room.matrix_room_id)
    end

    def matrix_id_to_slug(matrix_id)
      # strip the leading sigil and the :homeserver suffix, then sanitize
      localpart = matrix_id.to_s.sub(/\A[@!#]/, "").sub(/:.+\z/, "")
      localpart.empty? ? "unknown" : localpart
    end

    def sanitize(raw)
      raw.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
    end
  end
end
