# frozen_string_literal: true

module Discord
  # Matrix → Discord dispatcher. Plugged into `Matrix::SyncLoop` as the
  # `dispatcher:` argument; each batch of NormalizedEvents flows through
  # here on its way to Discord.
  #
  # For each event:
  #   1. Upsert the `Room` by matrix_room_id.
  #   2. Record / refresh the counterparty's username when that info is
  #      present and the sender is someone other than us or Reddit's
  #      system account.
  #   3. Resolve the target Discord channel via `ChannelIndex`.
  #   4. Format the event (author prefix + body) and post it.
  #   5. Advance `Room#last_event_id` only on success.
  #
  # Errors from the underlying Discord client (Auth / RateLimited /
  # ServerError / NotFound) propagate — the SyncLoop supervisor decides
  # whether to retry, alert, or pause. Poster itself is side-effect-only
  # and stateless beyond the Room it updates.
  class Poster
    OWN_PREFIX    = "📤 **You**"
    SYSTEM_PREFIX = "🤖 **Reddit**"

    def initialize(client:, channel_index:)
      @client = client
      @channel_index = channel_index
    end

    def call(events)
      events.each { |event| post_one(event) }
    end

    private

    def post_one(event)
      room = Room.find_or_create_by_matrix_id!(event.room_id)
      record_counterparty(room, event)
      channel_id = @channel_index.ensure_channel(room: room)
      @client.send_message(channel_id: channel_id, content: format_content(event))
      room.advance_event!(event.event_id)
    end

    def record_counterparty(room, event)
      return if event.own? || event.system?
      return if event.sender_username.blank?
      return if room.counterparty_username == event.sender_username

      room.record_counterparty!(matrix_id: event.sender, username: event.sender_username)
    end

    def format_content(event)
      "#{prefix_for(event)}\n#{event.body}"
    end

    def prefix_for(event)
      return OWN_PREFIX if event.own?
      return SYSTEM_PREFIX if event.system?

      "**#{display_name_for(event)}**"
    end

    def display_name_for(event)
      event.sender_username.presence || matrix_id_localpart(event.sender)
    end

    def matrix_id_localpart(matrix_id)
      matrix_id.to_s.sub(/\A@/, "").sub(/:.+\z/, "")
    end
  end
end
