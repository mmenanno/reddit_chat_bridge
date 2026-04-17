# frozen_string_literal: true

require "test_helper"
require "matrix/event_normalizer"
require "discord/client"
require "discord/channel_index"
require "discord/poster"

module Discord
  class PosterTest < ActiveSupport::TestCase
    ROOM_ID = "!abc:reddit.com"
    OWN = "@t2_me:reddit.com"
    PEER = "@t2_peer:reddit.com"
    SYSTEM = "@t2_1qwk:reddit.com"
    CHANNEL_ID = "555555555555555555"

    def setup
      super
      @client = Discord::Client.new(bot_token: "tok")
      @index = Discord::ChannelIndex.new(
        client: @client,
        guild_id: "guild",
        category_id: "cat",
      )
      @poster = Discord::Poster.new(client: @client, channel_index: @index)
      @index.stubs(:ensure_channel).returns(CHANNEL_ID)
    end

    test "posts every event in the batch through the client" do
      @client.expects(:send_message).with(channel_id: CHANNEL_ID, content: regexp_matches(/hi/)).returns("m1")
      @client.expects(:send_message).with(channel_id: CHANNEL_ID, content: regexp_matches(/bye/)).returns("m2")

      @poster.call([event(body: "hi", event_id: "$1"), event(body: "bye", event_id: "$2")])
    end

    test "creates a Room row for a previously unseen matrix_room_id" do
      assert_equal(0, Room.count)
      @client.stubs(:send_message).returns("m")

      @poster.call([event(body: "first-sighting")])

      assert_equal(1, Room.count)
      assert_equal(ROOM_ID, Room.first.matrix_room_id)
    end

    test "records the counterparty username the first time we see it" do
      @client.stubs(:send_message).returns("m")

      @poster.call([event(body: "hello", sender_username: "nothnnn")])

      assert_equal("nothnnn", Room.first.counterparty_username)
      assert_equal(PEER, Room.first.counterparty_matrix_id)
    end

    test "updates counterparty_username when Reddit changes their display name" do
      room = Room.create!(
        matrix_room_id: ROOM_ID,
        counterparty_matrix_id: PEER,
        counterparty_username: "oldname",
      )
      @client.stubs(:send_message).returns("m")

      @poster.call([event(body: "hi", sender_username: "newname")])

      assert_equal("newname", room.reload.counterparty_username)
    end

    test "does not record counterparty info from our own messages" do
      @client.stubs(:send_message).returns("m")

      @poster.call([event(sender: OWN, body: "self", sender_username: "RonanWolfe")])

      assert_nil(Room.first.counterparty_username)
    end

    test "does not record counterparty info from the Reddit system account" do
      @client.stubs(:send_message).returns("m")

      @poster.call([event(sender: SYSTEM, body: "moderation", sender_username: "RedditSystem")])

      assert_nil(Room.first.counterparty_username)
    end

    test "formats own messages with a 'You' prefix" do
      @client.expects(:send_message).with(
        channel_id: CHANNEL_ID,
        content: regexp_matches(/You.*\n.*self/m),
      ).returns("m")

      @poster.call([event(sender: OWN, body: "self")])
    end

    test "formats system messages with a 'Reddit' prefix" do
      @client.expects(:send_message).with(
        channel_id: CHANNEL_ID,
        content: regexp_matches(/Reddit.*\n.*notice/m),
      ).returns("m")

      @poster.call([event(sender: SYSTEM, body: "notice")])
    end

    test "formats peer messages with the resolved username when present" do
      @client.expects(:send_message).with(
        channel_id: CHANNEL_ID,
        content: regexp_matches(/nothnnn.*\n.*from peer/m),
      ).returns("m")

      @poster.call([event(body: "from peer", sender_username: "nothnnn")])
    end

    test "falls back to the matrix id in the prefix when no username is known" do
      @client.expects(:send_message).with(
        channel_id: CHANNEL_ID,
        content: regexp_matches(/t2_peer.*\n.*anon/m),
      ).returns("m")

      @poster.call([event(body: "anon", sender_username: nil)])
    end

    test "advances last_event_id after a successful post" do
      @client.stubs(:send_message).returns("m")

      @poster.call([event(event_id: "$evt_last")])

      assert_equal("$evt_last", Room.first.last_event_id)
    end

    test "re-raises when the client fails and leaves last_event_id unchanged" do
      room = Room.create!(matrix_room_id: ROOM_ID, last_event_id: "$prev")
      @client.stubs(:send_message).raises(Discord::ServerError, "503")

      assert_raises(Discord::ServerError) { @poster.call([event(event_id: "$new")]) }
      assert_equal("$prev", room.reload.last_event_id)
    end

    test "resolves the channel via the channel index for each event" do
      @index.unstub(:ensure_channel)
      @index.expects(:ensure_channel).with(has_entry(:room, instance_of(Room))).returns(CHANNEL_ID)
      @client.stubs(:send_message).returns("m")

      @poster.call([event])
    end

    private

    def event(
      event_id: "$default",
      sender: PEER,
      body: "hello",
      sender_username: nil,
      origin_server_ts: 1_776_400_000_000
    )
      Matrix::NormalizedEvent.new(
        room_id: ROOM_ID,
        event_id: event_id,
        kind: :message,
        sender: sender,
        sender_username: sender_username,
        body: body,
        origin_server_ts: origin_server_ts,
        is_own: sender == OWN,
        is_system: sender == SYSTEM,
      )
    end
  end
end
