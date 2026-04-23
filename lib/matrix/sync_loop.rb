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

    # Reddit's custom /sync extensions — server-computed unread counts that
    # drive the red badge in the web UI. Snapshot per batch into AppConfig
    # so the dashboard can surface what Reddit thinks our unread state is,
    # and so we can verify our outbound read markers are actually clearing
    # the counters server-side.
    COUNTER_KEYS = {
      "com.reddit.global_navigation_counter" => "reddit_counter_global_navigation",
      "com.reddit.main_timeline_counter" => "reddit_counter_main_timeline",
      "com.reddit.invites_counter" => "reddit_counter_invites",
      "com.reddit.spam_invites_counter" => "reddit_counter_spam_invites",
    }.freeze
    COUNTER_UPDATED_AT_KEY = "reddit_counters_updated_at"
    COUNTER_SCALAR_KEYS = ["unread", "count", "value"].freeze

    def initialize(client:, normalizer:, dispatcher:, invite_handler: nil, timeout_ms: DEFAULT_TIMEOUT_MS)
      @client = client
      @normalizer = normalizer
      @dispatcher = dispatcher
      @invite_handler = invite_handler
      @timeout_ms = timeout_ms
    end

    def iterate
      body = @client.sync(since: SyncCheckpoint.next_batch_token, timeout_ms: @timeout_ms)
      persist_reddit_counters!(body)
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

    private

    def persist_reddit_counters!(body)
      saw_any = false
      COUNTER_KEYS.each do |source_key, appconfig_key|
        next unless body.key?(source_key)

        value = extract_counter_value(body[source_key])
        next if value.nil?

        AppConfig.set(appconfig_key, value.to_s)
        saw_any = true
      end
      AppConfig.set(COUNTER_UPDATED_AT_KEY, Time.current.utc.iso8601) if saw_any
    end

    # Reddit hasn't documented the counter value shape. In practice we've
    # seen integer scalars; handle hash wrappers defensively in case the
    # server moves to `{unread: N}` / `{count: N}` later.
    def extract_counter_value(raw)
      return raw if raw.is_a?(Numeric)
      return unless raw.is_a?(Hash)

      COUNTER_SCALAR_KEYS.each do |key|
        v = raw[key]
        return v if v.is_a?(Numeric)
      end
      nil
    end
  end
end
