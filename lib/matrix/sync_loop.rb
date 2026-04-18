# frozen_string_literal: true

module Matrix
  # Drives one round-trip against the Reddit Matrix `/sync` endpoint:
  # fetch, normalize, dispatch, advance. Does exactly one iteration per
  # call — the long-lived "hold the thread open and keep syncing" shape
  # belongs one level up in the supervisor, not here.
  #
  # Success path:
  #   1. GET /sync?since=<checkpoint>
  #   2. Normalize the response into NormalizedEvent values.
  #   3. Hand the events to `dispatcher` (Phase 1 = a Discord poster,
  #      tests = a collector).
  #   4. Advance the checkpoint to the `next_batch` from the response.
  #   5. Mark auth healthy.
  #
  # The checkpoint advances *after* dispatch so a crash between receive
  # and post replays on restart — we never lose an event.
  #
  # Error handling:
  #   - `Matrix::TokenError` → mark auth as failed + paused, return :paused
  #   - `Matrix::ServerError` → re-raise; the outer supervisor decides on
  #     backoff and retry.
  #   - Dispatcher raising anything → re-raise; same supervisor policy.
  class SyncLoop
    # 10s long-poll keeps the worst-case shutdown wait to the same budget
    # (the supervisor can only check its stop signal between /sync calls).
    # Reddit sends events eagerly when they arrive, so this only controls
    # the idle-reconnect cadence — the extra HTTP round-trip every few
    # seconds is negligible overhead.
    DEFAULT_TIMEOUT_MS = 10_000

    def initialize(client:, normalizer:, dispatcher:, invite_handler: nil, timeout_ms: DEFAULT_TIMEOUT_MS)
      @client = client
      @normalizer = normalizer
      @dispatcher = dispatcher
      @invite_handler = invite_handler
      @timeout_ms = timeout_ms
    end

    def iterate
      body = @client.sync(since: SyncCheckpoint.next_batch_token, timeout_ms: @timeout_ms)
      @invite_handler&.call(body)
      events = @normalizer.normalize(body)
      @dispatcher.call(events)
      SyncCheckpoint.advance!(body["next_batch"])
      AuthState.mark_ok!
      :ok
    rescue Matrix::TokenError => e
      AuthState.mark_failure!(e.message)
      :paused
    end
  end
end
