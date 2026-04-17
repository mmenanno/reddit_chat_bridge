# frozen_string_literal: true

require "test_helper"
require "bridge/supervisor"
require "matrix/client"

module Bridge
  class SupervisorTest < ActiveSupport::TestCase
    class FakeSyncLoop
      attr_reader :iterations

      def initialize
        @iterations = 0
        @handler = -> { :ok }
      end

      def on_iterate(&block)
        @handler = block
      end

      def iterate
        @iterations += 1
        @handler.call
      end
    end

    def setup
      super
      @loop = FakeSyncLoop.new
    end

    test "one_tick calls iterate and returns the loop's outcome" do
      supervisor = Supervisor.new(sync_loop: @loop, sleeper: ->(_) {})

      assert_equal(:ok, supervisor.one_tick)
      assert_equal(1, @loop.iterations)
    end

    test "one_tick sleeps instead of iterating while auth is paused" do
      AuthState.mark_failure!("paused")
      sleeps = []
      supervisor = Supervisor.new(sync_loop: @loop, sleeper: ->(s) { sleeps << s })

      result = supervisor.one_tick

      assert_equal(:paused, result)
      assert_equal(0, @loop.iterations)
      refute_empty(sleeps)
    end

    test "one_tick retries a ServerError via the configured backoff policy" do
      attempts = 0
      @loop.on_iterate do
        attempts += 1
        raise(Matrix::ServerError, "503") if attempts < 3

        :ok
      end

      supervisor = Supervisor.new(
        sync_loop: @loop,
        sleeper: ->(_) {},
        retry_policy: Retry::Backoff::Policy.new(base: 0.01, factor: 2, max_sleep: 0.1, max_attempts: 5),
      )

      supervisor.one_tick

      assert_equal(3, @loop.iterations)
    end

    test "one_tick catches unexpected exceptions, alerts, and swallows them" do
      notifier = mock("notifier")
      notifier.expects(:critical).with(regexp_matches(/boom/), anything).once
      @loop.on_iterate { raise "boom" }

      supervisor = Supervisor.new(
        sync_loop: @loop,
        sleeper: ->(_) {},
        admin_notifier: notifier,
      )

      assert_nothing_raised { supervisor.one_tick }
    end
  end
end
