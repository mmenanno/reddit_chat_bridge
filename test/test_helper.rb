# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

ENV["RACK_ENV"] ||= "test"

require "minitest/autorun"
require "minitest/reporters"
require "active_support"
require "active_support/test_case"
require "active_support/testing/time_helpers"
require "mocha/minitest"
require "webmock/minitest"

# No test should ever reach the network.
WebMock.disable_net_connect!

Minitest::Reporters.use!(Minitest::Reporters::ProgressReporter.new)

require "bridge/boot"
# Parent-process boot — covers the serial fallback when the test count is
# below the parallelize threshold (running a single file, for example).
Bridge::Boot.call(database_path: ":memory:")

# bcrypt's default cost (12 rounds) is ~250ms per hash — by far the
# slowest single operation in the suite. Drop to MIN_COST for tests
# so AdminUser#update_password! and friends don't dominate the profile.
require "bcrypt"
BCrypt::Engine.cost = BCrypt::Engine::MIN_COST

module ActiveSupport
  class TestCase
    # Fork-based parallelism. Each worker is its own process so the
    # :memory: SQLite DB, Mocha mocks, WebMock state, and the
    # Bridge::Application singleton are all naturally isolated. Threaded
    # (`with: :threads`) would share those in one heap — none of them
    # are thread-safe in the ways we rely on.
    #
    # Worker count defaults to `:number_of_processors` (what `Etc.nprocessors`
    # reports), which is what developers want locally. GitHub Actions'
    # standard Linux runners underreport at 2 even though they give 4 vCPUs
    # to the job, so CI overrides with MINITEST_WORKERS=4.
    env_workers = ENV["MINITEST_WORKERS"].to_s.strip
    parallelize(
      workers: env_workers.empty? ? :number_of_processors : Integer(env_workers),
      with: :processes,
    )

    # Post-fork the inherited AR connection references a :memory: DB that
    # effectively no longer exists for the child. Drop it and re-run
    # Bridge::Boot so each worker owns a fresh connection + schema.
    parallelize_setup do |_worker|
      ActiveRecord::Base.connection_handler.clear_all_connections!
      Bridge::Boot.call(database_path: ":memory:")
    end

    parallelize_teardown do |_worker|
      ActiveRecord::Base.connection_handler.clear_all_connections!
    end

    # Rails auto-includes this; in our standalone setup it has to be
    # wired in manually. Gives every test travel_to / travel / freeze_time
    # with automatic cleanup — no Time.stubs needed.
    include ActiveSupport::Testing::TimeHelpers

    # Each test runs inside a transaction that's rolled back at teardown, so
    # the in-memory database returns to its post-migration state between tests.
    setup do
      ActiveRecord::Base.connection.begin_transaction(joinable: false)
    end

    teardown do
      # Bridge::Application is a process-wide singleton; any test that starts
      # its supervisor has to tear it down or the next test inherits state.
      Bridge::Application.shutdown! if defined?(Bridge::Application) && Bridge::Application.instance

      connection = ActiveRecord::Base.connection
      connection.rollback_transaction if connection.transaction_open?
    end
  end
end
