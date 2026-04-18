# frozen_string_literal: true

require "test_helper"

class RoomTest < ActiveSupport::TestCase
  MATRIX_ROOM_ID = "!abc:reddit.com"

  test "matrix_room_id is required" do
    room = Room.new

    refute_predicate(room, :valid?)
    assert_includes(room.errors[:matrix_room_id], "can't be blank")
  end

  test "matrix_room_id is unique" do
    Room.create!(matrix_room_id: MATRIX_ROOM_ID)
    dup = Room.new(matrix_room_id: MATRIX_ROOM_ID)

    refute_predicate(dup, :valid?)
    assert_includes(dup.errors[:matrix_room_id], "has already been taken")
  end

  test "find_or_create_by_matrix_id creates a row when none exists" do
    assert_equal(0, Room.count)

    Room.find_or_create_by_matrix_id!(MATRIX_ROOM_ID)

    assert_equal(1, Room.count)
  end

  test "find_or_create_by_matrix_id returns the existing row when present" do
    original = Room.find_or_create_by_matrix_id!(MATRIX_ROOM_ID)
    repeat = Room.find_or_create_by_matrix_id!(MATRIX_ROOM_ID)

    assert_equal(original.id, repeat.id)
    assert_equal(1, Room.count)
  end

  test "record_counterparty! stores the matrix id and username" do
    room = Room.find_or_create_by_matrix_id!(MATRIX_ROOM_ID)

    room.record_counterparty!(matrix_id: "@t2_peer:reddit.com", username: "nothnnn")

    assert_equal("@t2_peer:reddit.com", room.reload.counterparty_matrix_id)
    assert_equal("nothnnn", room.counterparty_username)
  end

  test "record_counterparty! overwrites an earlier username when it changes" do
    room = Room.find_or_create_by_matrix_id!(MATRIX_ROOM_ID)
    room.record_counterparty!(matrix_id: "@t2_peer:reddit.com", username: "oldname")

    room.record_counterparty!(matrix_id: "@t2_peer:reddit.com", username: "newname")

    assert_equal("newname", room.reload.counterparty_username)
  end

  test "attach_discord_channel! stores the Discord channel id" do
    room = Room.find_or_create_by_matrix_id!(MATRIX_ROOM_ID)

    room.attach_discord_channel!("123456789012345678")

    assert_equal("123456789012345678", room.reload.discord_channel_id)
  end

  test "advance_event! updates last_event_id" do
    room = Room.find_or_create_by_matrix_id!(MATRIX_ROOM_ID)

    room.advance_event!("$new_event")

    assert_equal("$new_event", room.reload.last_event_id)
  end

  test "is_direct defaults to true" do
    room = Room.find_or_create_by_matrix_id!(MATRIX_ROOM_ID)

    assert_predicate(room, :is_direct?)
  end

  test "archive! clears PostedEvent rows so Restore history can replay into the recreated channel" do
    room = Room.create!(matrix_room_id: MATRIX_ROOM_ID, discord_channel_id: "123")
    PostedEvent.record!(event_id: "$a", room_id: MATRIX_ROOM_ID)
    PostedEvent.record!(event_id: "$b", room_id: MATRIX_ROOM_ID)
    PostedEvent.record!(event_id: "$c", room_id: "!other:reddit.com") # unrelated — preserved

    room.archive!

    assert_equal(["$c"], PostedEvent.pluck(:event_id))
  end

  test "forget_posted_events! scopes to this room only" do
    room = Room.create!(matrix_room_id: MATRIX_ROOM_ID)
    PostedEvent.record!(event_id: "$a", room_id: MATRIX_ROOM_ID)
    PostedEvent.record!(event_id: "$z", room_id: "!other:reddit.com")

    room.forget_posted_events!

    assert_equal(["$z"], PostedEvent.pluck(:event_id))
  end
end
