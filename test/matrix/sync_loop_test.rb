# frozen_string_literal: true

require "test_helper"
require "matrix/client"
require "matrix/event_normalizer"
require "matrix/sync_loop"

module Matrix
  class SyncLoopTest < ActiveSupport::TestCase
    # Minimal dispatcher: records every batch of events it was asked to
    # deliver, and optionally raises when told to.
    class Collector
      attr_reader :batches

      def initialize
        @batches = []
        @raise_with = nil
      end

      def raise!(error_class, message = nil)
        @raise_with = [error_class, message]
      end

      def call(events)
        raise(@raise_with[0], @raise_with[1]) if @raise_with

        @batches << events
      end
    end

    def setup
      super
      @client = Matrix::Client.new(access_token: "tok")
      @normalizer = Matrix::EventNormalizer.new(own_user_id: "@t2_me:reddit.com")
      @dispatcher = Collector.new
      @loop = Matrix::SyncLoop.new(
        client: @client,
        normalizer: @normalizer,
        dispatcher: @dispatcher,
      )
    end

    test "iterate calls sync with no since token on a fresh checkpoint" do
      @client.expects(:sync).with(since: nil, timeout_ms: 10_000).returns(empty_body("n1"))

      @loop.iterate
    end

    test "iterate calls sync with the stored next_batch on subsequent runs" do
      SyncCheckpoint.advance!("stored_token")
      @client.expects(:sync).with(since: "stored_token", timeout_ms: 10_000).returns(empty_body("n2"))

      @loop.iterate
    end

    test "iterate passes the configured timeout_ms to the client" do
      custom = Matrix::SyncLoop.new(
        client: @client,
        normalizer: @normalizer,
        dispatcher: @dispatcher,
        timeout_ms: 5_000,
      )
      @client.expects(:sync).with(since: nil, timeout_ms: 5_000).returns(empty_body("n1"))

      custom.iterate
    end

    test "iterate dispatches the normalized events" do
      body = body_with_message(next_batch: "n1", room_id: "!r:reddit.com", body_text: "hi")
      @client.expects(:sync).returns(body)

      @loop.iterate

      batch = @dispatcher.batches.first

      assert_equal(1, batch.size)
      assert_equal("hi", batch.first.body)
    end

    test "iterate advances the checkpoint on success" do
      @client.expects(:sync).returns(empty_body("n_advance"))

      @loop.iterate

      assert_equal("n_advance", SyncCheckpoint.next_batch_token)
    end

    test "iterate marks auth state healthy on success" do
      AuthState.mark_failure!("previous failure")
      @client.expects(:sync).returns(empty_body("n1"))

      @loop.iterate

      refute_predicate(AuthState, :paused?)
    end

    test "iterate returns :ok on success" do
      @client.expects(:sync).returns(empty_body("n1"))

      assert_equal(:ok, @loop.iterate)
    end

    test "iterate returns :paused when the client raises TokenError" do
      @client.expects(:sync).raises(Matrix::TokenError, "M_UNKNOWN_TOKEN: bad")

      assert_equal(:paused, @loop.iterate)
    end

    test "iterate records the failure reason on TokenError" do
      @client.expects(:sync).raises(Matrix::TokenError, "M_UNKNOWN_TOKEN: bad")

      @loop.iterate

      assert_predicate(AuthState, :paused?)
      assert_match(/M_UNKNOWN_TOKEN/, AuthState.current.last_error)
    end

    test "iterate does not advance the checkpoint on TokenError" do
      SyncCheckpoint.advance!("safe_point")
      @client.expects(:sync).raises(Matrix::TokenError, "bad")

      @loop.iterate

      assert_equal("safe_point", SyncCheckpoint.next_batch_token)
    end

    test "iterate re-raises ServerError so the supervisor can back off" do
      @client.expects(:sync).raises(Matrix::ServerError, "503")

      assert_raises(Matrix::ServerError) { @loop.iterate }
    end

    test "iterate does not advance the checkpoint when ServerError bubbles up" do
      SyncCheckpoint.advance!("safe_point")
      @client.expects(:sync).raises(Matrix::ServerError, "503")

      assert_raises(Matrix::ServerError) { @loop.iterate }

      assert_equal("safe_point", SyncCheckpoint.next_batch_token)
    end

    test "iterate does not advance the checkpoint when the dispatcher raises" do
      SyncCheckpoint.advance!("safe_point")
      @client.expects(:sync).returns(empty_body("new_token"))
      @dispatcher.raise!(RuntimeError, "dispatcher boom")

      assert_raises(RuntimeError) { @loop.iterate }

      assert_equal("safe_point", SyncCheckpoint.next_batch_token)
    end

    # ---- invite handling ----

    test "iterate hands invites to the invite_handler before dispatching" do
      body = empty_body("n1")
      body["rooms"]["invite"] = { "!invite_a:reddit.com" => { "invite_state" => { "events" => [] } } }
      @client.expects(:sync).returns(body)
      handler = mock("InviteHandler")
      handler.expects(:call).with(body).once
      loop_with_handler = Matrix::SyncLoop.new(
        client: @client,
        normalizer: @normalizer,
        dispatcher: @dispatcher,
        invite_handler: handler,
      )

      loop_with_handler.iterate
    end

    test "iterate with no invite_handler does not auto-join or crash" do
      body = empty_body("n1")
      body["rooms"]["invite"] = { "!invite_a:reddit.com" => { "invite_state" => { "events" => [] } } }
      @client.expects(:sync).returns(body)
      @client.expects(:join_room).never

      @loop.iterate
    end

    private

    def empty_body(next_batch)
      { "next_batch" => next_batch, "rooms" => { "join" => {}, "invite" => {} } }
    end

    def body_with_message(next_batch:, room_id:, body_text:)
      {
        "next_batch" => next_batch,
        "rooms" => {
          "join" => {
            room_id => {
              "timeline" => {
                "events" => [{
                  "type" => "m.room.message",
                  "event_id" => "$evt",
                  "sender" => "@t2_other:reddit.com",
                  "origin_server_ts" => 1_776_400_000_000,
                  "content" => { "msgtype" => "m.text", "body" => body_text },
                }],
              },
              "state" => { "events" => [] },
            },
          },
        },
      }
    end
  end
end
