# frozen_string_literal: true

require "test_helper"
require "retry/backoff"

module Retry
  class BackoffTest < ActiveSupport::TestCase
    class Boom < StandardError; end
    class Other < StandardError; end

    test "returns the block's value when it succeeds on the first try" do
      backoff = Backoff.new(rescue_from: [Boom], sleep: ->(_) {})

      result = backoff.call { 42 }

      assert_equal(42, result)
    end

    test "retries a rescued error until it eventually succeeds" do
      calls = 0
      backoff = Backoff.new(rescue_from: [Boom], sleep: ->(_) {})

      result = backoff.call do
        calls += 1
        raise(Boom, "nope") if calls < 3

        :ok
      end

      assert_equal(:ok, result)
      assert_equal(3, calls)
    end

    test "raises after the configured attempt cap is exhausted" do
      calls = 0
      backoff = Backoff.new(
        rescue_from: [Boom],
        sleep: ->(_) {},
        policy: Backoff::Policy.new(base: 1, factor: 2, max_sleep: 60, max_attempts: 3),
      )

      assert_raises(Boom) do
        backoff.call do
          calls += 1
          raise(Boom, "never")
        end
      end

      assert_equal(3, calls)
    end

    test "does not catch errors outside the rescue_from list" do
      calls = 0
      backoff = Backoff.new(rescue_from: [Boom], sleep: ->(_) {})

      assert_raises(Other) do
        backoff.call do
          calls += 1
          raise(Other, "unexpected")
        end
      end

      assert_equal(1, calls)
    end

    test "sleeps with exponentially growing delays between attempts" do
      delays = []
      backoff = Backoff.new(
        rescue_from: [Boom],
        sleep: ->(s) { delays << s },
        policy: Backoff::Policy.new(base: 0.5, factor: 2, max_sleep: 60, max_attempts: 4),
      )

      calls = 0
      backoff.call do
        calls += 1
        raise(Boom, "still") if calls < 4

        :ok
      end

      assert_equal([0.5, 1.0, 2.0], delays)
    end

    test "caps the sleep at the configured ceiling" do
      delays = []
      backoff = Backoff.new(
        rescue_from: [Boom],
        sleep: ->(s) { delays << s },
        policy: Backoff::Policy.new(base: 10, factor: 10, max_sleep: 30, max_attempts: 4),
      )

      calls = 0
      assert_raises(Boom) do
        backoff.call do
          calls += 1
          raise(Boom, "still")
        end
      end

      assert_equal([10, 30, 30], delays)
    end
  end
end
