# frozen_string_literal: true

require "test_helper"
require "bridge/history_cutoff"

module Bridge
  class HistoryCutoffTest < ActiveSupport::TestCase
    NOW = Time.utc(2026, 6, 16, 12, 0, 0)

    setup do
      @cutoff = Bridge::HistoryCutoff.new
    end

    test "returns nil when neither lookback nor date is configured" do
      assert_nil(@cutoff.cutoff_time(now: NOW))
    end

    test "treats blank and zero lookback as disabled" do
      AppConfig.set("bridge_history_lookback_days", "0")
      AppConfig.set("bridge_history_cutoff_date", "")

      assert_nil(@cutoff.cutoff_time(now: NOW))
    end

    test "lookback-only returns now minus the configured days" do
      AppConfig.set("bridge_history_lookback_days", "30")

      assert_equal(NOW - 30.days, @cutoff.cutoff_time(now: NOW))
    end

    test "date-only returns midnight UTC of the configured date" do
      AppConfig.set("bridge_history_cutoff_date", "2025-01-01")

      assert_equal(Time.utc(2025, 1, 1), @cutoff.cutoff_time(now: NOW))
    end

    test "with both set the more recent (max) boundary wins" do
      # lookback (30 days) -> 2026-05-17; date -> 2025-01-01; lookback is later
      AppConfig.set("bridge_history_lookback_days", "30")
      AppConfig.set("bridge_history_cutoff_date", "2025-01-01")

      assert_equal(NOW - 30.days, @cutoff.cutoff_time(now: NOW))
    end

    test "with both set picks the date when it is the later boundary" do
      # lookback (3650 days) -> ~2016; date -> 2026-06-01; date is later
      AppConfig.set("bridge_history_lookback_days", "3650")
      AppConfig.set("bridge_history_cutoff_date", "2026-06-01")

      assert_equal(Time.utc(2026, 6, 1), @cutoff.cutoff_time(now: NOW))
    end

    test "non-integer lookback is treated as disabled" do
      AppConfig.set("bridge_history_lookback_days", "thirty")

      assert_nil(@cutoff.cutoff_time(now: NOW))
    end

    test "unparseable date is treated as disabled" do
      AppConfig.set("bridge_history_cutoff_date", "not-a-date")

      assert_nil(@cutoff.cutoff_time(now: NOW))
    end

    test "reads config live so changes take effect without reconstruction" do
      assert_nil(@cutoff.cutoff_time(now: NOW))

      AppConfig.set("bridge_history_lookback_days", "7")

      assert_equal(NOW - 7.days, @cutoff.cutoff_time(now: NOW))
    end
  end
end
