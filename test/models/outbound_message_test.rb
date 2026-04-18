# frozen_string_literal: true

require "test_helper"

class OutboundMessageTest < ActiveSupport::TestCase
  test "register_sent! upserts a row with status=sent + event_id" do
    record = OutboundMessage.register_sent!(
      txn_id: "t1",
      discord_message_id: "d1",
      matrix_room_id: "!r:reddit.com",
      matrix_event_id: "$e1",
    )

    assert_equal("sent", record.status)
    assert_equal("$e1", record.matrix_event_id)
    refute_nil(record.sent_at)
  end

  test "register_failure! stores the error and marks status=failed" do
    record = OutboundMessage.register_failure!(
      txn_id: "t2",
      discord_message_id: "d2",
      matrix_room_id: "!r:reddit.com",
      error: "M_LIMIT_EXCEEDED",
    )

    assert_equal("failed", record.status)
    assert_equal("M_LIMIT_EXCEEDED", record.last_error)
  end

  test "posted_event? answers whether an event_id was sent by us" do
    OutboundMessage.register_sent!(
      txn_id: "t3",
      discord_message_id: "d3",
      matrix_room_id: "!r:reddit.com",
      matrix_event_id: "$e3",
    )

    assert(OutboundMessage.posted_event?("$e3"))
    refute(OutboundMessage.posted_event?("$unknown"))
  end
end
