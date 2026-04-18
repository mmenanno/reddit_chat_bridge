# frozen_string_literal: true

require "test_helper"
require "bridge/journal"

module Bridge
  class JournalTest < ActiveSupport::TestCase
    def setup
      super
      @notifier = mock("notifier")
      @logger = mock("logger")
      @journal = Bridge::Journal.new(admin_notifier: @notifier, logger: @logger)
    end

    test "info writes to the event log and forwards to the Discord logger" do
      @logger.expects(:info).with("hello")

      @journal.info("hello", source: "test")

      entry = EventLogEntry.last

      assert_equal("info", entry.level)
      assert_equal("hello", entry.message)
      assert_equal("test", entry.source)
    end

    test "warn writes warn-level entries and sends a Discord warn" do
      @notifier.expects(:warn).with("careful")

      @journal.warn("careful")

      assert_equal("warn", EventLogEntry.last.level)
    end

    test "critical pages via the notifier and records at critical level" do
      @notifier.expects(:critical).with("boom", ping_everyone: true)

      @journal.critical("boom", ping_everyone: true)

      assert_equal("critical", EventLogEntry.last.level)
    end

    test "works with neither notifier nor logger injected" do
      j = Bridge::Journal.new
      j.info("just db")

      assert_equal(1, EventLogEntry.where(message: "just db").count)
    end
  end
end
