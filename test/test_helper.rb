# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "minitest/reporters"
require "active_support"
require "active_support/test_case"
require "mocha/minitest"

Minitest::Reporters.use!(Minitest::Reporters::ProgressReporter.new)

require "bridge/boot"
Bridge::Boot.call(database_path: ":memory:")

module ActiveSupport
  class TestCase
    # Each test runs inside a transaction that's rolled back at teardown, so
    # the in-memory database returns to its post-migration state between tests.
    setup do
      ActiveRecord::Base.connection.begin_transaction(joinable: false)
    end

    teardown do
      connection = ActiveRecord::Base.connection
      connection.rollback_transaction if connection.transaction_open?
    end
  end
end
