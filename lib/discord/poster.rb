# frozen_string_literal: true

module Discord
  # Matrix → Discord dispatcher. Plugged into `Matrix::SyncLoop` as the
  # `dispatcher:` argument; each batch of NormalizedEvents flows through
  # here on its way to Discord.
  #
  # For each event:
  #   1. Short-circuit if `PostedEvent` already has its event_id — the
  #      checkpoint must have rewound, this event already went out.
  #   2. Upsert the `Room` by matrix_room_id.
  #   3. Record / refresh the counterparty's username when that info is
  #      present and the sender is someone other than us or Reddit's
  #      system account.
  #   4. Resolve the target Discord channel via `ChannelIndex`.
  #   5. Format the event (author prefix + body) and post it — with
  #      transparent retry on Discord::RateLimited (respects retry_after)
  #      and channel-rebuild on Discord::NotFound (operator deleted the
  #      channel; next sync reconciles without human intervention).
  #   6. Record the event_id in PostedEvent and advance `Room#last_event_id`.
  class Poster
    OWN_PREFIX    = "📤 **You**"
    SYSTEM_PREFIX = "🤖 **Reddit**"

    RATE_LIMIT_MAX_ATTEMPTS = 3
    RATE_LIMIT_FALLBACK_SLEEP = 1.0

    def initialize(client:, channel_index:, sleeper: Kernel.method(:sleep))
      @client = client
      @channel_index = channel_index
      @sleeper = sleeper
    end

    def call(events)
      events.each { |event| post_one(event) }
    end

    private

    def post_one(event)
      return if PostedEvent.posted?(event.event_id)

      room = Room.find_or_create_by_matrix_id!(event.room_id)
      record_counterparty(room, event)
      send_with_channel_recovery(room, event)
      PostedEvent.record!(event_id: event.event_id, room_id: event.room_id)
      room.advance_event!(event.event_id)
    end

    def send_with_channel_recovery(room, event)
      channel_id = @channel_index.ensure_channel(room: room)
      send_with_rate_limit_retry(channel_id: channel_id, content: format_content(event))
    rescue Discord::NotFound
      # Operator deleted the channel; forget the stale id and let
      # ChannelIndex create a fresh one on the retry.
      room.update!(discord_channel_id: nil)
      channel_id = @channel_index.ensure_channel(room: room.reload)
      send_with_rate_limit_retry(channel_id: channel_id, content: format_content(event))
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
