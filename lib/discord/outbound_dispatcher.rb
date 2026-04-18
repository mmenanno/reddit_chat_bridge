# frozen_string_literal: true

require "securerandom"

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
  class OutboundDispatcher
    def initialize(matrix_client:, operator_discord_ids: [], journal: nil)
      @matrix_client = matrix_client
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
