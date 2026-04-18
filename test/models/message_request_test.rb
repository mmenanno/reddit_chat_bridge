# frozen_string_literal: true

require "test_helper"

class MessageRequestTest < ActiveSupport::TestCase
  ROOM = "!abc:reddit.com"

  test "starts in a pending state with neither decision flag set" do
    req = MessageRequest.create!(matrix_room_id: ROOM)

    assert_predicate(req, :pending?)
    refute_predicate(req, :approved?)
  end

  test "brand-new requests are not declined either" do
    refute_predicate(MessageRequest.create!(matrix_room_id: ROOM), :declined?)
  end

  test "resolve! records the decision + timestamp and flips the predicates" do
    req = MessageRequest.create!(matrix_room_id: ROOM)
    frozen = Time.utc(2026, 4, 18, 12, 0)

    req.resolve!(decision: MessageRequest::APPROVED, at: frozen)

    assert_equal(
      { decision: MessageRequest::APPROVED, resolved_at: frozen, pending: false, approved: true },
      decision: req.decision,
      resolved_at: req.resolved_at,
      pending: req.pending?,
      approved: req.approved?,
    )
  end

  test "pending scope excludes resolved rows" do
    MessageRequest.create!(matrix_room_id: "!a:reddit.com")
    MessageRequest.create!(matrix_room_id: "!b:reddit.com", resolved_at: Time.current, decision: "approved")

    assert_equal(["!a:reddit.com"], MessageRequest.pending.pluck(:matrix_room_id))
  end

  test "display_name prefers username, falls back to matrix id localpart, then 'unknown'" do
    assert_equal("testuser", MessageRequest.new(inviter_username: "testuser").display_name)
    assert_equal("t2_peer", MessageRequest.new(inviter_matrix_id: "@t2_peer:reddit.com").display_name)
    assert_equal("unknown", MessageRequest.new.display_name)
  end

  test "matrix_room_id uniqueness is enforced" do
    MessageRequest.create!(matrix_room_id: ROOM)

    assert_raises(ActiveRecord::RecordInvalid) do
      MessageRequest.create!(matrix_room_id: ROOM)
    end
  end
end
