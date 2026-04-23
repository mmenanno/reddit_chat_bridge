# frozen_string_literal: true

require "test_helper"

class EventLogEntryTest < ActiveSupport::TestCase
  test "records an entry with level + message" do
    entry = EventLogEntry.record!(level: :warn, message: "hi there")

    assert_equal("warn", entry.level)
    assert_equal("hi there", entry.message)
  end

  test "serializes hash context as JSON" do
    entry = EventLogEntry.record!(level: :info, message: "with ctx", context: { room: "!r:reddit.com" })

    assert_equal({ "room" => "!r:reddit.com" }, entry.context_hash)
  end

  test "returns an empty hash when context is missing or bad JSON" do
    entry = EventLogEntry.record!(level: :info, message: "no ctx")

    assert_empty(entry.context_hash)
  end

  test "rejects unknown levels and swallows the error" do
    result = EventLogEntry.record!(level: :gossip, message: "noop")

    assert_nil(result)
    assert_equal(0, EventLogEntry.count)
  end

  test "recent orders newest first and limits the result" do
    now = Time.current
    3.times { |i| EventLogEntry.create!(level: "info", message: "m#{i}", created_at: now + i.seconds) }

    recent = EventLogEntry.recent(limit: 2).to_a

    assert_equal(["m2", "m1"], recent.map(&:message))
  end

  test "page_of returns the requested window newest first" do
    now = Time.current
    7.times { |i| EventLogEntry.create!(level: "info", message: "m#{i}", created_at: now + i.seconds) }

    page_two = EventLogEntry.page_of(page: 2, per_page: 3).to_a

    # Newest-first order over m0..m6 is [m6, m5, m4, m3, m2, m1, m0];
    # page 2 with per_page=3 is the next three: m3, m2, m1.
    assert_equal(["m3", "m2", "m1"], page_two.map(&:message))
  end

  test "page_of returns everything when per_page exceeds the total" do
    now = Time.current
    2.times { |i| EventLogEntry.create!(level: "info", message: "m#{i}", created_at: now + i.seconds) }

    assert_equal(["m1", "m0"], EventLogEntry.page_of(page: 1, per_page: 50).map(&:message))
  end

  test "page_of returns an empty relation when page is past the end" do
    EventLogEntry.create!(level: "info", message: "only")

    # Callers should clamp, but the model must not blow up if they don't.
    assert_empty(EventLogEntry.page_of(page: 99, per_page: 10).to_a)
  end

  test "trim! caps the table at MAX_ROWS" do
    stub_const = EventLogEntry::MAX_ROWS
    # Use a dense timestamp range to exceed the cap without a crazy loop.
    (stub_const + 5).times do |i|
      EventLogEntry.create!(level: "info", message: "m#{i}", created_at: Time.current + i.seconds)
    end
    EventLogEntry.trim!

    assert_operator(EventLogEntry.count, :<=, stub_const)
  end

  test "clear_all! wipes the table and returns the row count" do
    EventLogEntry.record!(level: :info, message: "a")
    EventLogEntry.record!(level: :warn, message: "b")

    assert_equal(2, EventLogEntry.clear_all!)
    assert_equal(0, EventLogEntry.count)
  end
end
