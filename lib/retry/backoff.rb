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
      rescue *@rescue_from
        raise if attempt >= @policy.max_attempts

        @sleep.call(delay_for(attempt))
        retry
      end
    end

    private

    def delay_for(attempt)
      raw = @policy.base * (@policy.factor**(attempt - 1))
      [raw, @policy.max_sleep].min
    end
  end
end
