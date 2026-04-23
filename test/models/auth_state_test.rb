# frozen_string_literal: true

require "test_helper"

class AuthStateTest < ActiveSupport::TestCase
  test "current creates the singleton row when the table is empty" do
    assert_equal(0, AuthState.count)

    state = AuthState.current

    assert_equal(1, AuthState.count)
    assert_predicate(state, :persisted?)
  end

  test "current returns the same row across repeated calls" do
    first = AuthState.current
    second = AuthState.current

    assert_equal(first.id, second.id)
    assert_equal(1, AuthState.count)
  end

  test "update_token! stores the new access_token and user_id" do
    AuthState.update_token!(access_token: "tok_123", user_id: "@t2_abc:reddit.com")

    assert_equal("tok_123", AuthState.access_token)
    assert_equal("@t2_abc:reddit.com", AuthState.user_id)
  end

  test "update_token! unpauses the state and clears the failure record" do
    AuthState.mark_failure!("something broke")

    AuthState.update_token!(access_token: "new", user_id: "@t2_x:reddit.com")

    refute_predicate(AuthState, :paused?)
    assert_equal(0, AuthState.current.consecutive_failures)
    assert_nil(AuthState.current.last_error)
  end

  test "update_token! stamps last_ok_at" do
    AuthState.update_token!(access_token: "new", user_id: "@t2_x:reddit.com")

    assert_not_nil(AuthState.current.last_ok_at)
  end

  test "mark_failure! pauses the state" do
    AuthState.mark_failure!("M_UNKNOWN_TOKEN")

    assert_predicate(AuthState, :paused?)
  end

  test "mark_failure! records the reason and increments the failure count" do
    AuthState.mark_failure!("M_UNKNOWN_TOKEN")

    assert_equal("M_UNKNOWN_TOKEN", AuthState.current.last_error)
    assert_equal(1, AuthState.current.consecutive_failures)
  end

  test "mark_failure! tags paused_reason as token_rejected" do
    AuthState.mark_failure!("M_UNKNOWN_TOKEN")

    assert_equal("token_rejected", AuthState.current.paused_reason)
    refute_predicate(AuthState, :paused_by_operator?)
  end

  test "mark_failure! increments consecutive_failures across repeated calls" do
    3.times { |i| AuthState.mark_failure!("failure #{i}") }

    assert_equal(3, AuthState.current.consecutive_failures)
    assert_equal("failure 2", AuthState.current.last_error)
  end

  test "mark_ok! unpauses the state" do
    AuthState.mark_failure!("M_UNKNOWN_TOKEN")

    AuthState.mark_ok!

    refute_predicate(AuthState, :paused?)
  end

  test "mark_ok! clears the failure record" do
    AuthState.mark_failure!("boom")

    AuthState.mark_ok!

    assert_equal(0, AuthState.current.consecutive_failures)
    assert_nil(AuthState.current.last_error)
  end

  test "mark_ok! clears paused_reason" do
    AuthState.mark_failure!("boom")

    AuthState.mark_ok!

    assert_nil(AuthState.current.paused_reason)
  end

  test "mark_ok! stamps last_ok_at" do
    AuthState.mark_ok!

    assert_not_nil(AuthState.current.last_ok_at)
  end

  test "access_token and user_id read through to the singleton row" do
    AuthState.update_token!(access_token: "live", user_id: "@t2_x:reddit.com")

    assert_equal("live", AuthState.access_token)
    assert_equal("@t2_x:reddit.com", AuthState.user_id)
  end

  test "pause_by_operator! pauses and tags the reason" do
    AuthState.pause_by_operator!

    assert_predicate(AuthState, :paused?)
    assert_predicate(AuthState, :paused_by_operator?)
    assert_equal("operator", AuthState.current.paused_reason)
  end

  test "pause_by_operator! clears any stale last_error from a previous auto-pause" do
    AuthState.mark_failure!("M_UNKNOWN_TOKEN")

    AuthState.pause_by_operator!

    assert_nil(AuthState.current.last_error)
  end

  test "pause_by_operator! does not touch last_ok_at or consecutive_failures" do
    AuthState.update_token!(access_token: "live", user_id: "@t2_x:reddit.com")
    prior_ok = AuthState.current.last_ok_at
    AuthState.mark_failure!("transient")
    prior_failures = AuthState.current.consecutive_failures

    AuthState.pause_by_operator!

    assert_equal(prior_ok, AuthState.current.last_ok_at)
    assert_equal(prior_failures, AuthState.current.consecutive_failures)
  end

  test "resume_by_operator! unpauses and clears paused_reason" do
    AuthState.pause_by_operator!

    AuthState.resume_by_operator!

    refute_predicate(AuthState, :paused?)
    assert_nil(AuthState.current.paused_reason)
  end

  test "resume_by_operator! leaves last_ok_at alone so telemetry reflects reality" do
    AuthState.update_token!(access_token: "live", user_id: "@t2_x:reddit.com")
    prior_ok = AuthState.current.last_ok_at
    AuthState.pause_by_operator!

    AuthState.resume_by_operator!

    assert_equal(prior_ok, AuthState.current.last_ok_at)
  end

  test "paused_by_operator? is false when paused by token rejection" do
    AuthState.mark_failure!("M_UNKNOWN_TOKEN")

    assert_predicate(AuthState, :paused?)
    refute_predicate(AuthState, :paused_by_operator?)
  end

  test "paused_by_operator? is false when not paused at all" do
    refute_predicate(AuthState, :paused?)
    refute_predicate(AuthState, :paused_by_operator?)
  end
end
