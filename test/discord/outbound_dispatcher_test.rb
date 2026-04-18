# frozen_string_literal: true

require "test_helper"
require "discord/outbound_dispatcher"
require "matrix/client"

module Discord
  class OutboundDispatcherTest < ActiveSupport::TestCase
    OP_USER_ID = "998877"

    def setup
      super
      @matrix = mock("MatrixClient")
      @dispatcher = OutboundDispatcher.new(
        matrix_client: @matrix,
        operator_discord_ids: [OP_USER_ID],
      )
      @room = Room.create!(
        matrix_room_id: "!r:reddit.com",
        counterparty_matrix_id: "@t2_peer:reddit.com",
        counterparty_username: "peer",
        discord_channel_id: "12345",
      )
    end

    test "relays an operator's message to Matrix and records the event id" do
      @matrix.expects(:send_message)
        .with(has_entries(room_id: "!r:reddit.com", body: "hi reddit"))
        .returns("$evt_123")

      @dispatcher.dispatch(discord_message_hash("hi reddit"))

      outbound = OutboundMessage.find_by(matrix_event_id: "$evt_123")

      assert_equal("sent", outbound.status)
      assert_equal("!r:reddit.com", outbound.matrix_room_id)
    end

    test "ignores bot authors" do
      @matrix.expects(:send_message).never
      msg = discord_message_hash("bot line")
      msg["author"]["bot"] = true

      @dispatcher.dispatch(msg)
    end

    test "ignores messages from a non-operator when the allow-list is set" do
      @matrix.expects(:send_message).never
      msg = discord_message_hash("hi")
      msg["author"]["id"] = "222"

      @dispatcher.dispatch(msg)
    end

    test "accepts any non-bot author when the operator list is empty" do
      dispatcher = OutboundDispatcher.new(matrix_client: @matrix, operator_discord_ids: [])
      @matrix.expects(:send_message).returns("$e")

      dispatcher.dispatch(discord_message_hash("anyone"))
    end

    test "ignores messages in channels that aren't bridged" do
      @matrix.expects(:send_message).never
      msg = discord_message_hash("x")
      msg["channel_id"] = "unbridged"

      @dispatcher.dispatch(msg)
    end

    test "records a failure row when Matrix rejects the send" do
      @matrix.expects(:send_message).raises(Matrix::Error, "M_FORBIDDEN")

      @dispatcher.dispatch(discord_message_hash("nope"))

      failure = OutboundMessage.last

      assert_equal("failed", failure.status)
      assert_match(/M_FORBIDDEN/, failure.last_error)
    end

    private

    def discord_message_hash(content)
      {
        "id" => "discord_msg_#{SecureRandom.hex(4)}",
        "channel_id" => "12345",
        "type" => 0,
        "content" => content,
        "author" => { "id" => OP_USER_ID, "bot" => false },
      }
    end
  end
end
