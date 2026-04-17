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
    end

    def one_tick
      refresh_matrix_token_if_near_expiry

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
  end
end
