# frozen_string_literal: true

require "test_helper"
require "discord/client"
require "discord/outbound_dispatcher"
require "matrix/client"

module Discord
  class OutboundDispatcherTest < ActiveSupport::TestCase
    OP_USER_ID = "998877"

    setup do
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

    # ---- Reddit-persona rewrite (post-then-delete) ----

    test "after a successful Matrix send, replaces the Discord message with a webhook repost under the Reddit identity" do
      AppConfig.set("matrix_user_id", "@t2_me:reddit.com")
      AppConfig.set("own_display_name", "RonanWolfe")
      AppConfig.set("own_avatar_url", "https://cdn/snoo.png")
      discord_client = mock("DiscordClient")
      channel_index = mock("ChannelIndex")
      dispatcher = OutboundDispatcher.new(
        matrix_client: @matrix,
        discord_client: discord_client,
        channel_index: channel_index,
        operator_discord_ids: [OP_USER_ID],
      )
      msg = discord_message_hash("hello redditor")

      @matrix.expects(:send_message).returns("$evt")
      channel_index.expects(:ensure_webhook).with(has_entry(:room, @room)).returns(["wh_id", "wh_tok"])
      discord_client.expects(:execute_webhook).with do |kwargs|
        kwargs[:webhook_id] == "wh_id" &&
          kwargs[:payload][:username] == "RonanWolfe \u{1F4E4}" &&
          kwargs[:payload][:avatar_url] == "https://cdn/snoo.png" &&
          kwargs[:payload][:content] == "hello redditor"
      end.returns("id" => "new_webhook_msg")
      discord_client.expects(:delete_message).with(channel_id: "12345", message_id: msg["id"])

      dispatcher.dispatch(msg)
    end

    test "skips the persona rewrite gracefully when discord_client + channel_index aren't wired" do
      # Default @dispatcher has neither — proves the rewrite is opt-in.
      @matrix.expects(:send_message).returns("$evt")

      assert_nothing_raised { @dispatcher.dispatch(discord_message_hash("hi")) }
    end

    test "logs and swallows webhook execute failures instead of aborting the dispatch" do
      AppConfig.set("matrix_user_id", "@t2_me:reddit.com")
      AppConfig.set("own_display_name", "RonanWolfe")
      AppConfig.set("own_avatar_url", "https://cdn/snoo.png")
      journal = mock("Journal")
      journal.stubs(:info)
      journal.expects(:warn).with(regexp_matches(/persona rewrite failed/i), source: "outbound")
      discord_client = mock("DiscordClient")
      channel_index = mock("ChannelIndex")
      channel_index.expects(:ensure_webhook).returns(["wh", "tok"])
      discord_client.expects(:execute_webhook).raises(Discord::ServerError, "503")
      discord_client.expects(:delete_message).never
      dispatcher = OutboundDispatcher.new(
        matrix_client: @matrix,
        discord_client: discord_client,
        channel_index: channel_index,
        operator_discord_ids: [OP_USER_ID],
        journal: journal,
      )

      @matrix.expects(:send_message).returns("$evt")

      dispatcher.dispatch(discord_message_hash("hi"))
    end

    test "falls back to Matrix /profile when AppConfig has no cached own identity" do
      AppConfig.set("matrix_user_id", "@t2_me:reddit.com")
      AppConfig.set("own_display_name", "")
      AppConfig.set("own_avatar_url", "")
      media_resolver = mock("MediaResolver")
      media_resolver.expects(:resolve).with("mxc://server/avatar").returns("https://cdn/resolved.png")
      discord_client = mock("DiscordClient")
      channel_index = mock("ChannelIndex")
      channel_index.stubs(:ensure_webhook).returns(["wh", "tok"])
      dispatcher = OutboundDispatcher.new(
        matrix_client: @matrix,
        discord_client: discord_client,
        channel_index: channel_index,
        media_resolver: media_resolver,
        operator_discord_ids: [OP_USER_ID],
      )

      @matrix.expects(:send_message).returns("$evt")
      @matrix.expects(:profile).with(user_id: "@t2_me:reddit.com").returns(
        "displayname" => "RonanWolfe",
        "avatar_url" => "mxc://server/avatar",
      )
      discord_client.expects(:execute_webhook).with do |kwargs|
        kwargs[:payload][:username] == "RonanWolfe \u{1F4E4}" &&
          kwargs[:payload][:avatar_url] == "https://cdn/resolved.png"
      end.returns("id" => "new_msg")
      discord_client.expects(:delete_message)

      dispatcher.dispatch(discord_message_hash("hi"))

      assert_equal("RonanWolfe", AppConfig.fetch("own_display_name", ""))
      assert_equal("https://cdn/resolved.png", AppConfig.fetch("own_avatar_url", ""))
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
