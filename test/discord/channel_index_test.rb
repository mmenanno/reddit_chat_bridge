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
      @client.stubs(:create_channel).returns("444")

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
      @client.stubs(:create_channel).raises(Discord::AuthError, "401")

      assert_raises(Discord::AuthError) { @index.ensure_channel(room: room) }
      assert_nil(room.reload.discord_channel_id)
    end
  end
end
