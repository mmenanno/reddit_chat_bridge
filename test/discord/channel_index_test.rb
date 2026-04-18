# frozen_string_literal: true

require "test_helper"
require "discord/client"
require "discord/channel_index"

module Discord
  class ChannelIndexTest < ActiveSupport::TestCase
    GUILD = "111111111111111111"
    CATEGORY = "222222222222222222"

    def setup
      super
      @client = Discord::Client.new(bot_token: "tok")
      @index = Discord::ChannelIndex.new(
        client: @client,
        guild_id: GUILD,
        category_id: CATEGORY,
      )
    end

    test "returns the existing channel_id when the room already has one" do
      room = Room.create!(matrix_room_id: "!r:reddit.com", discord_channel_id: "333")
      @client.expects(:create_channel).never

      assert_equal("333", @index.ensure_channel(room: room))
    end

    test "creates a channel for a room without one and returns its id" do
      room = Room.create!(
        matrix_room_id: "!r:reddit.com",
        counterparty_username: "nothnnn",
      )
      @client.expects(:create_channel).with(
        guild_id: GUILD,
        name: "dm-nothnnn",
        parent_id: CATEGORY,
      ).returns("444")

      assert_equal("444", @index.ensure_channel(room: room))
    end

    test "attaches the created channel id to the Room record" do
      room = Room.create!(
        matrix_room_id: "!r:reddit.com",
        counterparty_username: "nothnnn",
      )
      @client.expects(:create_channel).returns("444")

      @index.ensure_channel(room: room)

      assert_equal("444", room.reload.discord_channel_id)
    end

    test "sanitizes uppercase usernames to lowercase" do
      room = Room.create!(
        matrix_room_id: "!r:reddit.com",
        counterparty_username: "RonanWolfe",
      )
      @client.expects(:create_channel).with(
        guild_id: GUILD,
        name: "dm-ronanwolfe",
        parent_id: CATEGORY,
      ).returns("444")

      @index.ensure_channel(room: room)
    end

    test "replaces characters Discord would reject with dashes" do
      room = Room.create!(
        matrix_room_id: "!r:reddit.com",
        counterparty_username: "weird name!!",
      )
      @client.expects(:create_channel).with(
        guild_id: GUILD,
        name: "dm-weird-name",
        parent_id: CATEGORY,
      ).returns("444")

      @index.ensure_channel(room: room)
    end

    test "falls back to the counterparty matrix id when username is nil" do
      room = Room.create!(
        matrix_room_id: "!room_abc:reddit.com",
        counterparty_matrix_id: "@t2_peer:reddit.com",
        counterparty_username: nil,
      )
      @client.expects(:create_channel).with(
        guild_id: GUILD,
        name: "dm-t2-peer",
        parent_id: CATEGORY,
      ).returns("444")

      @index.ensure_channel(room: room)
    end

    test "falls back to a room-derived name when no counterparty info exists yet" do
      room = Room.create!(matrix_room_id: "!room_abc:reddit.com")
      @client.expects(:create_channel).with(
        guild_id: GUILD,
        name: "dm-room-abc",
        parent_id: CATEGORY,
      ).returns("444")

      @index.ensure_channel(room: room)
    end

    test "propagates AuthError so the admin layer can alert" do
      room = Room.create!(matrix_room_id: "!r:reddit.com", counterparty_username: "peer")
      @client.expects(:create_channel).raises(Discord::AuthError, "401")

      assert_raises(Discord::AuthError) { @index.ensure_channel(room: room) }
      assert_nil(room.reload.discord_channel_id)
    end

    # ---- webhooks ----

    test "returns the cached webhook pair when the room already has one" do
      room = Room.create!(
        matrix_room_id: "!r:reddit.com",
        discord_channel_id: "555",
        discord_webhook_id: "wh_1",
        discord_webhook_token: "tok_1",
      )
      @client.expects(:create_webhook).never

      assert_equal(["wh_1", "tok_1"], @index.ensure_webhook(room: room))
    end

    test "creates a webhook on the channel the first time and persists id + token" do
      room = Room.create!(
        matrix_room_id: "!r:reddit.com",
        discord_channel_id: "555",
        counterparty_username: "testuser",
      )
      @client.expects(:create_webhook)
        .with(channel_id: "555", name: "Reddit Chat Bridge")
        .returns("id" => "wh_1", "token" => "tok_1")

      assert_equal(["wh_1", "tok_1"], @index.ensure_webhook(room: room))
      assert_equal("wh_1", room.reload.discord_webhook_id)
      assert_equal("tok_1", room.discord_webhook_token)
    end

    test "creates the channel first when the room has no channel yet" do
      room = Room.create!(matrix_room_id: "!r:reddit.com", counterparty_username: "peer")
      @client.expects(:create_channel).returns("999")
      @client.expects(:create_webhook).with(channel_id: "999", name: "Reddit Chat Bridge").returns(
        "id" => "wh_2", "token" => "tok_2",
      )

      @index.ensure_webhook(room: room)

      assert_equal("999", room.reload.discord_channel_id)
      assert_equal("wh_2", room.discord_webhook_id)
    end

    test "clears the stale discord_channel_id when Discord 404s on webhook creation" do
      room = Room.create!(
        matrix_room_id: "!r:reddit.com",
        discord_channel_id: "gone",
        counterparty_username: "peer",
      )
      @client.expects(:create_webhook).raises(Discord::NotFound, "Unknown Channel")

      assert_raises(Discord::NotFound) { @index.ensure_webhook(room: room) }
      assert_nil(room.reload.discord_channel_id)
    end
  end
end
