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
      @sleeps = []
      @poster = Discord::Poster.new(
        client: @client,
        channel_index: @index,
        sleeper: ->(s) { @sleeps << s },
      )
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

    test "appends resolved media URLs to the Discord message so it auto-embeds" do
      @client.expects(:send_message).with(
        channel_id: CHANNEL_ID,
        content: regexp_matches(%r{📎 photo\.jpg.*https://matrix\.redditspace\.com/_matrix/media}m),
      ).returns("m")

      @poster.call([event(
        kind: :media,
        body: "photo.jpg",
        sender_username: "nothnnn",
        media_url: "https://matrix.redditspace.com/_matrix/media/v3/download/matrix.redditspace.com/abc",
      )])
    end

    test "uses the Room's stored counterparty_username when the event doesn't carry one" do
      Room.create!(
        matrix_room_id: ROOM_ID,
        counterparty_matrix_id: PEER,
        counterparty_username: "jinxieRay",
        discord_channel_id: CHANNEL_ID,
      )
      @client.expects(:send_message).with(
        channel_id: CHANNEL_ID,
        content: regexp_matches(/jinxieRay.*\n.*later msg/m),
      ).returns("m")

      @poster.call([event(body: "later msg", sender_username: nil)])
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

    # ---- idempotency ----

    test "skips events already present in PostedEvent" do
      PostedEvent.record!(event_id: "$seen", room_id: ROOM_ID)
      @client.expects(:send_message).never

      @poster.call([event(event_id: "$seen")])
    end

    test "records posted event_id so checkpoint rewinds don't cause duplicates" do
      @client.stubs(:send_message).returns("m")

      @poster.call([event(event_id: "$once")])
      # Simulate a checkpoint rewind: same batch comes back on next iteration.
      @poster.call([event(event_id: "$once")])

      assert_equal(1, PostedEvent.where(event_id: "$once").count)
    end

    # ---- rate limit retry ----

    test "retries on RateLimited and sleeps for retry_after_ms" do
      raise_once = false
      @client.stubs(:send_message).with do |*_|
        if raise_once
          true # succeed the second time
        else
          raise_once = true
          raise(Discord::RateLimited.new("slow down", retry_after_ms: 2500))
        end
      end.returns("m")

      @poster.call([event])

      assert_equal([2.5], @sleeps)
    end

    test "gives up on persistent RateLimited after the attempt cap" do
      @client.stubs(:send_message).raises(Discord::RateLimited.new("still", retry_after_ms: 100))

      assert_raises(Discord::RateLimited) { @poster.call([event]) }
    end

    # ---- channel recovery on 404 ----

    test "clears stale discord_channel_id and retries when Discord returns NotFound" do
      room = Room.create!(
        matrix_room_id: ROOM_ID,
        discord_channel_id: "old_chan",
        counterparty_username: "peer",
      )
      @index.unstub(:ensure_channel)
      @index.stubs(:ensure_channel).returns(CHANNEL_ID)
      @client.stubs(:send_message)
        .raises(Discord::NotFound, "Unknown Channel")
        .then
        .returns("msg-id")

      @poster.call([event])

      # The recovery path cleared the stale id before the second ensure_channel
      # call. In production ensure_channel would re-attach the new id; our stub
      # doesn't, so observing nil proves the clear happened.
      assert_nil(room.reload.discord_channel_id)
    end

    test "calls send_message twice when the first attempt hits NotFound and the second succeeds" do
      Room.create!(
        matrix_room_id: ROOM_ID,
        discord_channel_id: "old_chan",
        counterparty_username: "peer",
      )
      @client.expects(:send_message).twice
        .raises(Discord::NotFound, "Unknown Channel")
        .then
        .returns("msg-id")

      @poster.call([event])
    end

    # ---- content truncation + BadRequest handling ----

    test "truncates content longer than Discord's 2000-char cap" do
      @client.expects(:send_message).with do |kwargs|
        body = kwargs[:content]
        body.length <= 2000 && body.end_with?("…[truncated]")
      end.returns("m")

      long = "a" * 3000
      @poster.call([event(body: long)])
    end

    test "records PostedEvent and skips forward on Discord::BadRequest instead of looping" do
      @client.stubs(:send_message).raises(Discord::BadRequest, "Invalid Form Body")

      @poster.call([event(event_id: "$bad")])

      # Event is marked posted so the next sync iteration doesn't replay it.
      assert(PostedEvent.posted?("$bad"))
    end

    # ---- matrix_id fallback when username can't be resolved ----

    test "records counterparty_matrix_id even when sender_username is nil" do
      @client.stubs(:send_message).returns("m")

      @poster.call([event(body: "hi", sender_username: nil)])

      assert_equal(PEER, Room.first.counterparty_matrix_id)
      assert_nil(Room.first.counterparty_username)
    end

    # ---- profile fallback via Matrix::Client ----

    test "falls back to Matrix::Client#profile when sender_username is nil" do
      matrix_client = mock("MatrixClient")
      matrix_client.expects(:profile).with(user_id: PEER).returns("displayname" => "nothnnn")
      poster = Discord::Poster.new(
        client: @client,
        channel_index: @index,
        matrix_client: matrix_client,
        sleeper: ->(_) {},
      )
      @client.stubs(:send_message).returns("m")

      poster.call([event(body: "hi", sender_username: nil)])

      assert_equal("nothnnn", Room.first.counterparty_username)
    end

    # ---- channel rename on username resolution ----

    test "renames the Discord channel when the username resolves after the channel was created" do
      room = Room.create!(
        matrix_room_id: ROOM_ID,
        counterparty_matrix_id: PEER,
        discord_channel_id: "chan_123",
      )
      @client.stubs(:send_message).returns("m")
      @client.expects(:rename_channel).with(channel_id: "chan_123", name: "dm-nothnnn").returns(:ok)

      @poster.call([event(body: "hi", sender_username: "nothnnn")])

      assert_equal("nothnnn", room.reload.counterparty_username)
    end

    test "resolves the channel via the channel index for each event" do
      @index.unstub(:ensure_channel)
      @index.expects(:ensure_channel).with(has_entry(:room, instance_of(Room))).returns(CHANNEL_ID)
      @client.stubs(:send_message).returns("m")

      @poster.call([event])
    end

    private

    def event( # rubocop:disable Metrics/ParameterLists
      event_id: "$default",
      sender: PEER,
      body: "hello",
      sender_username: nil,
      origin_server_ts: 1_776_400_000_000,
      kind: :message,
      media_url: nil,
      media_mime: nil
    )
      Matrix::NormalizedEvent.new(
        room_id: ROOM_ID,
        event_id: event_id,
        kind: kind,
        sender: sender,
        sender_username: sender_username,
        body: body,
        origin_server_ts: origin_server_ts,
        is_own: sender == OWN,
        is_system: sender == SYSTEM,
        media_url: media_url,
        media_mime: media_mime,
      )
    end
  end
end
