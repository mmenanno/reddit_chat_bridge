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

# No test should ever reach the network; the spike scripts are the only
# real-endpoint surface in this repo.
WebMock.disable_net_connect!

Minitest::Reporters.use!(Minitest::Reporters::ProgressReporter.new)

require "bridge/boot"
# Parent-process boot — covers the serial fallback when the test count is
# below the parallelize threshold (running a single file, for example).
Bridge::Boot.call(database_path: ":memory:")

module ActiveSupport
  class TestCase
    # Fork-based parallelism. Each worker is its own process so the
    # :memory: SQLite DB, Mocha mocks, WebMock state, and the
    # Bridge::Application singleton are all naturally isolated. Threaded
    # (`with: :threads`) would share those in one heap — none of them
    # are thread-safe in the ways we rely on.
    parallelize(workers: :number_of_processors, with: :processes)

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
