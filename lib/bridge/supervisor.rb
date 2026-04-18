# frozen_string_literal: true

require "matrix/client"
require "retry/backoff"

module Bridge
  # Wraps `Matrix::SyncLoop#iterate` with the policy it deliberately doesn't
  # implement itself: retry on transient server errors, stop iterating while
  # auth is paused, alert on anything unexpected, and never die silently.
  #
  # Designed for one `one_tick` to be testable in isolation; the production
  # entrypoint `run_forever` just loops `one_tick` until asked to stop.
  class Supervisor
    DEFAULT_RETRY_POLICY = Retry::Backoff::Policy.new(
      base: 2.0, factor: 2.0, max_sleep: 300.0, max_attempts: 6,
    )
    PAUSED_SLEEP_SECONDS = 5
    POSTED_EVENT_PRUNE_INTERVAL = 1.hour
    COOKIE_EXPIRY_WARN_KEY = "reddit_session_warned_expires_at"

    def initialize(
      sync_loop:,
      admin_notifier: nil,
      admin_actions: nil,
      sleeper: Kernel.method(:sleep),
      retry_policy: DEFAULT_RETRY_POLICY
    )
      @sync_loop = sync_loop
      @admin_notifier = admin_notifier
      @admin_actions = admin_actions
      @sleeper = sleeper
      @backoff = Retry::Backoff.new(
        rescue_from: [Matrix::ServerError],
        policy: retry_policy,
        sleep: sleeper,
      )
      @last_prune_at = nil
    end

    def one_tick
      refresh_matrix_token_if_near_expiry
      warn_if_reddit_session_expiring_soon
      prune_posted_events_periodically

      if AuthState.paused?
        @sleeper.call(PAUSED_SLEEP_SECONDS)
        return :paused
      end

      @backoff.call { @sync_loop.iterate }
    rescue Matrix::ServerError => e
      alert_critical("Matrix server errors exhausted retries: #{e.message}")
      :error
    rescue StandardError => e
      alert_critical("Sync loop crashed: #{e.class}: #{e.message}")
      :error
    end

    def run_forever(stop_signal: ->(*) { false })
      loop do
        break if stop_signal.call

        one_tick
      end
    end

    private

    def alert_critical(message)
      @admin_notifier&.critical(message, ping_everyone: false)
    end

    # Matrix JWTs live 24h; refresh them when <1h remains. The refresh path
    # requires stored Reddit cookies — if they're absent, this is a no-op
    # (the operator is driving manually via /auth).
    def refresh_matrix_token_if_near_expiry
      return unless @admin_actions
      return unless AuthState.reddit_cookie_jar
      return unless AuthState.access_token_expiring_soon?(within: 1.hour)

      @admin_actions.refresh_matrix_token!
    rescue Auth::RefreshFlow::RefreshError => e
      @admin_notifier&.warn("Auto-refresh failed: #{e.message}")
    end

    # The reddit_session JWT inside the cookie jar is what lets the refresh
    # flow keep minting Matrix tokens. It lives ~6 months. When we're inside
    # the warning window (default 7 days), fire exactly one admin alert so
    # the operator has time to paste a fresh cookie header. Idempotent on
    # the expiry timestamp itself so a restart doesn't re-spam.
    def warn_if_reddit_session_expiring_soon
      return unless @admin_notifier
      return unless AuthState.reddit_session_expiring_soon?

      expires_at = AuthState.reddit_session_expires_at
      return unless expires_at
      return if AppConfig.fetch(COOKIE_EXPIRY_WARN_KEY, "") == expires_at.iso8601

      @admin_notifier.warn(
        "Reddit session cookie expires #{expires_at.utc.iso8601} — paste a fresh Cookie header on /auth.",
      )
      AppConfig.set(COOKIE_EXPIRY_WARN_KEY, expires_at.iso8601)
    end

    # PostedEvent grows unbounded without this. Pruning once per hour keeps
    # the table small without hammering the DB or consuming tick budget.
    def prune_posted_events_periodically
      now = Time.current
      return if @last_prune_at && (now - @last_prune_at) < POSTED_EVENT_PRUNE_INTERVAL

      PostedEvent.prune!
      @last_prune_at = now
    rescue StandardError => e
      @admin_notifier&.warn("PostedEvent.prune! failed: #{e.message}")
    end
  end
end
