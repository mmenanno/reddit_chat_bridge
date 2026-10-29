# frozen_string_literal: true

require "test_helper"
require "bridge/supervisor"
require "faraday"
require "matrix/client"
require "auth/refresh_flow"

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

    setup do
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

    test "failed auto-refresh warns once and is not retried on every paused tick" do
      AuthState.mark_failure!("paused")
      AuthState.stubs(:reddit_cookie_jar).returns("jar")
      AuthState.stubs(:access_token_expiring_soon?).returns(true)
      actions = mock("actions")
      actions.expects(:refresh_matrix_token!).once.raises(Auth::RefreshFlow::RefreshError.new("no <rs-app token=...> in /chat/ response"))
      journal = mock("journal")
      journal.expects(:warn).once.with("Auto-refresh failed: no <rs-app token=...> in /chat/ response", source: "supervisor")
      supervisor = Supervisor.new(sync_loop: @loop, admin_actions: actions, journal: journal, sleeper: ->(_) {})

      3.times { supervisor.one_tick }
    end

    test "failed auto-refresh is retried after the retry interval but an identical error is not re-announced" do
      AuthState.mark_failure!("paused")
      AuthState.stubs(:reddit_cookie_jar).returns("jar")
      AuthState.stubs(:access_token_expiring_soon?).returns(true)
      actions = mock("actions")
      actions.expects(:refresh_matrix_token!).twice.raises(Auth::RefreshFlow::RefreshError.new("boom"))
      journal = mock("journal")
      journal.expects(:warn).once
      supervisor = Supervisor.new(sync_loop: @loop, admin_actions: actions, journal: journal, sleeper: ->(_) {})

      supervisor.one_tick
      travel(Supervisor::REFRESH_RETRY_INTERVAL + 1.second) { supervisor.one_tick }
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

    test "one_tick retries a Matrix::RateLimited 429 in-tick without alerting" do
      attempts = 0
      @loop.on_iterate do
        attempts += 1
        raise(Matrix::RateLimited.new("M_LIMIT_EXCEEDED: too many sync requests", retry_after_ms: nil)) if attempts < 2

        :ok
      end
      notifier = mock("notifier")
      notifier.expects(:critical).never

      supervisor = Supervisor.new(
        sync_loop: @loop,
        admin_notifier: notifier,
        sleeper: ->(_) {},
        retry_policy: Retry::Backoff::Policy.new(base: 0.01, factor: 2, max_sleep: 0.1, max_attempts: 5),
      )

      assert_equal(:ok, supervisor.one_tick)
      assert_equal(2, @loop.iterations)
    end

    test "one_tick retries Faraday::ConnectionFailed via the configured backoff policy" do
      attempts = 0
      @loop.on_iterate do
        attempts += 1
        raise(Faraday::ConnectionFailed, "Network is unreachable") if attempts < 3

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

    test "one_tick alerts once (not per attempt) when Faraday::ConnectionFailed exhausts retries" do
      notifier = mock("notifier")
      notifier.expects(:critical).with(regexp_matches(/ConnectionFailed/), anything).once
      @loop.on_iterate { raise(Faraday::ConnectionFailed, "Network is unreachable") }

      supervisor = Supervisor.new(
        sync_loop: @loop,
        sleeper: ->(_) {},
        admin_notifier: notifier,
        retry_policy: Retry::Backoff::Policy.new(base: 0.01, factor: 2, max_sleep: 0.01, max_attempts: 2),
      )

      assert_equal(:error, supervisor.one_tick)
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

    # ---- CRITICAL dedupe across ticks ----

    test "one_tick does not re-fire CRITICAL when the same upstream error repeats on the next tick" do
      notifier = mock("notifier")
      notifier.expects(:critical).with(regexp_matches(/streaming token/), anything).once
      @loop.on_iterate do
        raise(Matrix::ServerError, "M_INVALID_ARGUMENT_VALUE: unable to get streaming token")
      end

      supervisor = Supervisor.new(
        sync_loop: @loop,
        sleeper: ->(_) {},
        admin_notifier: notifier,
        retry_policy: Retry::Backoff::Policy.new(base: 0.01, factor: 2, max_sleep: 0.01, max_attempts: 1),
      )

      3.times { supervisor.one_tick }
    end

    test "one_tick fires CRITICAL again when the error message changes between ticks" do
      notifier = mock("notifier")
      notifier.expects(:critical).with(regexp_matches(/streaming token/), anything).once
      notifier.expects(:critical).with(regexp_matches(/503/), anything).once
      call = 0
      @loop.on_iterate do
        call += 1
        raise(Matrix::ServerError, call == 1 ? "M_INVALID_ARGUMENT_VALUE: unable to get streaming token" : "503")
      end

      supervisor = Supervisor.new(
        sync_loop: @loop,
        sleeper: ->(_) {},
        admin_notifier: notifier,
        retry_policy: Retry::Backoff::Policy.new(base: 0.01, factor: 2, max_sleep: 0.01, max_attempts: 1),
      )

      supervisor.one_tick
      supervisor.one_tick
    end

    test "one_tick re-fires CRITICAL after a recovery if the same error recurs later" do
      notifier = mock("notifier")
      notifier.expects(:critical).with(regexp_matches(/streaming token/), anything).twice
      notifier.stubs(:info) # recovery announcement, not under test here
      scenario = [:fail, :ok, :fail]
      @loop.on_iterate do
        next(:ok) unless scenario.shift == :fail

        raise(Matrix::ServerError, "M_INVALID_ARGUMENT_VALUE: unable to get streaming token")
      end

      supervisor = Supervisor.new(
        sync_loop: @loop,
        sleeper: ->(_) {},
        admin_notifier: notifier,
        retry_policy: Retry::Backoff::Policy.new(base: 0.01, factor: 2, max_sleep: 0.01, max_attempts: 1),
      )

      3.times { supervisor.one_tick }
    end

    # ---- sync-recovered announcement ----

    test "one_tick announces sync recovered via journal after consecutive failed ticks succeed" do
      journal = mock("journal")
      journal.stubs(:critical)
      journal.expects(:info).with(regexp_matches(/recovered after 2 failed/), source: "supervisor").once
      scenario = [:fail, :fail, :ok]
      @loop.on_iterate do
        next(:ok) unless scenario.shift == :fail

        raise(Matrix::ServerError, "streaming token")
      end

      supervisor = Supervisor.new(
        sync_loop: @loop,
        sleeper: ->(_) {},
        journal: journal,
        retry_policy: Retry::Backoff::Policy.new(base: 0.01, factor: 2, max_sleep: 0.01, max_attempts: 1),
      )

      3.times { supervisor.one_tick }
    end

    test "one_tick does not announce recovery when there was no prior failure" do
      journal = mock("journal")
      journal.expects(:info).never
      supervisor = Supervisor.new(sync_loop: @loop, sleeper: ->(_) {}, journal: journal)

      supervisor.one_tick
    end

    test "one_tick does not re-announce recovery on a second consecutive successful tick" do
      journal = mock("journal")
      journal.stubs(:critical)
      journal.expects(:info).with(regexp_matches(/recovered/), source: "supervisor").once
      scenario = [:fail, :ok, :ok]
      @loop.on_iterate do
        next(:ok) unless scenario.shift == :fail

        raise(Matrix::ServerError, "streaming token")
      end

      supervisor = Supervisor.new(
        sync_loop: @loop,
        sleeper: ->(_) {},
        journal: journal,
        retry_policy: Retry::Backoff::Policy.new(base: 0.01, factor: 2, max_sleep: 0.01, max_attempts: 1),
      )

      3.times { supervisor.one_tick }
    end

    # ---- cookie expiry warning ----

    test "warns exactly once when reddit_session enters the 7-day window" do
      AppConfig.set("session_secret", "t" * 64)
      AuthState.current.update_columns(reddit_session_expires_at: 3.days.from_now)
      notifier = mock("notifier")
      notifier.expects(:warn).with(regexp_matches(/expires/)).once
      supervisor = Supervisor.new(sync_loop: @loop, sleeper: ->(_) {}, admin_notifier: notifier)

      supervisor.one_tick
      supervisor.one_tick # second tick must not re-warn
    end

    test "re-warns when the expiry changes (cookie rotated)" do
      AppConfig.set("session_secret", "t" * 64)
      AuthState.current.update_columns(reddit_session_expires_at: 3.days.from_now)
      notifier = mock("notifier")
      notifier.expects(:warn).twice
      supervisor = Supervisor.new(sync_loop: @loop, sleeper: ->(_) {}, admin_notifier: notifier)

      supervisor.one_tick
      AuthState.current.update_columns(reddit_session_expires_at: 2.days.from_now)
      supervisor.one_tick
    end

    test "does not warn when reddit_session is still weeks out" do
      AppConfig.set("session_secret", "t" * 64)
      AuthState.current.update_columns(reddit_session_expires_at: 30.days.from_now)
      notifier = mock("notifier")
      notifier.expects(:warn).never
      supervisor = Supervisor.new(sync_loop: @loop, sleeper: ->(_) {}, admin_notifier: notifier)

      supervisor.one_tick
    end

    # ---- PostedEvent pruning ----

    test "prunes PostedEvent on the first tick and then skips for an hour" do
      PostedEvent.expects(:prune!).once
      supervisor = Supervisor.new(sync_loop: @loop, sleeper: ->(_) {})

      supervisor.one_tick
      supervisor.one_tick # same tick window, no second prune
    end

    test "swallows prune failures and reports via admin_notifier" do
      notifier = mock("notifier")
      notifier.expects(:warn).with(regexp_matches(/prune/i))
      PostedEvent.expects(:prune!).raises(StandardError, "db gone")
      supervisor = Supervisor.new(sync_loop: @loop, sleeper: ->(_) {}, admin_notifier: notifier)

      assert_nothing_raised { supervisor.one_tick }
    end
  end
end
