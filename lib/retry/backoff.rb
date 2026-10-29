# frozen_string_literal: true

module Retry
  # Exponential-backoff retry wrapper.
  #
  # Deliberately narrow and explicit: the caller picks which errors to
  # rescue and supplies a `Policy` describing the curve. No jitter (our
  # scale doesn't have a thundering-herd problem), no magic global
  # defaults — every call site is free to tune the curve for its needs.
  #
  # Uses an injected `sleep` callable so tests don't actually block.
  class Backoff
    Policy = Data.define(:base, :factor, :max_sleep, :max_attempts)
    DEFAULT_POLICY = Policy.new(base: 1.0, factor: 2.0, max_sleep: 300.0, max_attempts: 5)

    def initialize(rescue_from:, policy: DEFAULT_POLICY, sleep: Kernel.method(:sleep))
      @rescue_from = Array(rescue_from)
      @policy = policy
      @sleep = sleep
    end

    def call
      attempt = 0

      begin
        attempt += 1
        yield
      rescue *@rescue_from => exception
        raise if attempt >= @policy.max_attempts

        @sleep.call(delay_for(attempt, exception))
        retry
      end
    end

    private

    # Errors that carry a server-supplied wait hint (`retry_after_ms`, e.g.
    # Matrix 429s) never sleep shorter than the hint; the curve still sets
    # the floor and `max_sleep` still caps the total.
    def delay_for(attempt, exception)
      raw = @policy.base * (@policy.factor**(attempt - 1))
      hint_ms = exception.respond_to?(:retry_after_ms) ? exception.retry_after_ms : nil
      raw = [raw, hint_ms / 1000.0].max if hint_ms
      [raw, @policy.max_sleep].min
    end
  end
end
