# frozen_string_literal: true

require "test_helper"

class SyncCheckpointTest < ActiveSupport::TestCase
  test "current creates the singleton row on first access" do
    assert_equal(0, SyncCheckpoint.count)

    SyncCheckpoint.current

    assert_equal(1, SyncCheckpoint.count)
  end

  test "current returns the same row across repeated calls" do
    first = SyncCheckpoint.current
    second = SyncCheckpoint.current

    assert_equal(first.id, second.id)
  end

  test "next_batch_token is nil on a fresh checkpoint" do
    assert_nil(SyncCheckpoint.next_batch_token)
  end

  test "advance! stores the new next_batch_token" do
    SyncCheckpoint.advance!("batch_abc")

    assert_equal("batch_abc", SyncCheckpoint.next_batch_token)
  end

  test "advance! stamps last_batch_at" do
    SyncCheckpoint.advance!("batch_abc")

    assert_not_nil(SyncCheckpoint.current.last_batch_at)
  end

  test "advance! replaces an earlier token" do
    SyncCheckpoint.advance!("one")
    SyncCheckpoint.advance!("two")

    assert_equal("two", SyncCheckpoint.next_batch_token)
  end

  test "reset! clears the next_batch_token" do
    SyncCheckpoint.advance!("one")

    SyncCheckpoint.reset!

    assert_nil(SyncCheckpoint.next_batch_token)
  end
end
