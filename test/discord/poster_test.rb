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
    WEBHOOK_ID = "wh_1"
    WEBHOOK_TOKEN = "tok_1"

    setup do
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
      @index.stubs(:ensure_webhook).returns([WEBHOOK_ID, WEBHOOK_TOKEN])
    end

    test "posts every event in the batch through the webhook" do
      @client.expects(:execute_webhook)
        .with(webhook_id: WEBHOOK_ID, webhook_token: WEBHOOK_TOKEN, payload: has_entry(content: regexp_matches(/hi/)))
        .returns("m1")
      @client.expects(:execute_webhook)
        .with(webhook_id: WEBHOOK_ID, webhook_token: WEBHOOK_TOKEN, payload: has_entry(content: regexp_matches(/bye/)))
        .returns("m2")

      @poster.call([event(body: "hi", event_id: "$1"), event(body: "bye", event_id: "$2")])
    end

    test "creates a Room row for a previously unseen matrix_room_id" do
      assert_equal(0, Room.count)
      @client.expects(:execute_webhook).at_least_once.returns("m")

      @poster.call([event(body: "first-sighting")])

      assert_equal(1, Room.count)
      assert_equal(ROOM_ID, Room.first.matrix_room_id)
    end

    test "records the counterparty username the first time we see it" do
      @client.expects(:execute_webhook).at_least_once.returns("m")

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
      @client.expects(:execute_webhook).at_least_once.returns("m")

      @poster.call([event(body: "hi", sender_username: "newname")])

      assert_equal("newname", room.reload.counterparty_username)
    end

    test "does not record counterparty info from our own messages" do
      @client.expects(:execute_webhook).at_least_once.returns("m")

      @poster.call([event(sender: OWN, body: "self", sender_username: "RonanWolfe")])

      assert_nil(Room.first.counterparty_username)
    end

    test "does not record counterparty info from the Reddit system account" do
      @client.expects(:execute_webhook).at_least_once.returns("m")

      @poster.call([event(sender: SYSTEM, body: "moderation", sender_username: "RedditSystem")])

      assert_nil(Room.first.counterparty_username)
    end

    # ---- username + avatar on the webhook payload ----

    test "own messages post with the sender's name suffixed by 📤 so it's distinct from native Discord" do
      @client.expects(:execute_webhook).with do |kwargs|
        kwargs[:payload][:username] == "RonanWolfe \u{1F4E4}" && kwargs[:payload][:content] == "self"
      end.returns("m")

      @poster.call([event(sender: OWN, body: "self", sender_username: "RonanWolfe")])
    end

    test "system messages post as 'Reddit'" do
      @client.expects(:execute_webhook).with do |kwargs|
        kwargs[:payload][:username] == "Reddit" && kwargs[:payload][:content] == "notice"
      end.returns("m")

      @poster.call([event(sender: SYSTEM, body: "notice")])
    end

    test "peer messages post under the resolved counterparty username" do
      @client.expects(:execute_webhook).with do |kwargs|
        kwargs[:payload][:username] == "nothnnn" && kwargs[:payload][:content] == "from peer"
      end.returns("m")

      @poster.call([event(body: "from peer", sender_username: "nothnnn")])
    end

    test "falls back to the matrix_id localpart as the webhook username when no display name is known" do
      @client.expects(:execute_webhook).with do |kwargs|
        kwargs[:payload][:username] == "t2_peer" && kwargs[:payload][:content] == "anon"
      end.returns("m")

      @poster.call([event(body: "anon", sender_username: nil)])
    end

    test "passes sender_avatar_url through to the webhook when present" do
      @client.expects(:execute_webhook).with do |kwargs|
        kwargs[:payload][:avatar_url] == "https://cdn/u.png"
      end.returns("m")

      @poster.call([event(body: "hi", sender_username: "nothnnn", sender_avatar_url: "https://cdn/u.png")])
    end

    test "omits avatar_url entirely when the sender has no resolved avatar and no profile client" do
      @client.expects(:execute_webhook).with do |kwargs|
        !kwargs[:payload].key?(:avatar_url)
      end.returns("m")

      @poster.call([event(body: "hi", sender_avatar_url: nil)])
    end

    # ---- Reddit profile avatar fallback ----

    test "falls back to Reddit profile avatar when the event has no avatar and the room has a counterparty username" do
      Room.create!(matrix_room_id: ROOM_ID, counterparty_matrix_id: PEER, counterparty_username: "jinxieRay")
      profile = mock("ProfileClient")
      profile.expects(:fetch_avatar_url).with("jinxieRay").returns("https://i.redd.it/snoovatar/j.png")
      poster = Poster.new(
        client: @client,
        channel_index: @index,
        reddit_profile_client: profile,
        sleeper: ->(_) {},
      )
      @client.expects(:execute_webhook).with do |kwargs|
        kwargs[:payload][:avatar_url] == "https://i.redd.it/snoovatar/j.png"
      end.returns("m")

      poster.call([event(body: "hi", sender_avatar_url: nil)])
    end

    test "caches the resolved profile avatar on the room so the next event skips the API call" do
      Room.create!(matrix_room_id: ROOM_ID, counterparty_matrix_id: PEER, counterparty_username: "jinxieRay")
      profile = mock("ProfileClient")
      profile.expects(:fetch_avatar_url).once.returns("https://i.redd.it/snoovatar/j.png")
      poster = Poster.new(
        client: @client,
        channel_index: @index,
        reddit_profile_client: profile,
        sleeper: ->(_) {},
      )
      @client.expects(:execute_webhook).at_least_once.returns("m")

      poster.call([event(event_id: "$1", sender_avatar_url: nil), event(event_id: "$2", sender_avatar_url: nil)])
    end

    test "skips the profile client on own and system events even without an avatar" do
      profile = mock("ProfileClient")
      profile.expects(:fetch_avatar_url).never
      poster = Poster.new(
        client: @client,
        channel_index: @index,
        reddit_profile_client: profile,
        sleeper: ->(_) {},
      )
      @client.expects(:execute_webhook).at_least_once.returns("m")

      poster.call([
        event(event_id: "$own", sender: OWN, body: "me"),
        event(event_id: "$sys", sender: SYSTEM, body: "notice"),
      ])
    end

    test "negative-caches a Reddit profile miss so we don't re-hit the API for 24h" do
      Room.create!(
        matrix_room_id: ROOM_ID,
        counterparty_matrix_id: PEER,
        counterparty_username: "ghost",
        counterparty_avatar_checked_at: 1.hour.ago,
      )
      profile = mock("ProfileClient")
      profile.expects(:fetch_avatar_url).never
      poster = Poster.new(
        client: @client,
        channel_index: @index,
        reddit_profile_client: profile,
        sleeper: ->(_) {},
      )
      @client.expects(:execute_webhook).at_least_once.returns("m")

      poster.call([event(sender_avatar_url: nil)])
    end

    test "retries the Reddit profile API after the 24h negative-cache window passes" do
      Room.create!(
        matrix_room_id: ROOM_ID,
        counterparty_matrix_id: PEER,
        counterparty_username: "comeback",
        counterparty_avatar_checked_at: 2.days.ago,
      )
      profile = mock("ProfileClient")
      profile.expects(:fetch_avatar_url).with("comeback").returns("https://i.redd.it/x.png")
      poster = Poster.new(
        client: @client,
        channel_index: @index,
        reddit_profile_client: profile,
        sleeper: ->(_) {},
      )
      @client.expects(:execute_webhook).at_least_once.returns("m")

      poster.call([event(sender_avatar_url: nil)])
    end

    test "uses the Room's stored counterparty_username when the event doesn't carry one" do
      Room.create!(
        matrix_room_id: ROOM_ID,
        counterparty_matrix_id: PEER,
        counterparty_username: "jinxieRay",
        discord_channel_id: CHANNEL_ID,
      )
      @client.expects(:execute_webhook).with do |kwargs|
        kwargs[:payload][:username] == "jinxieRay" && kwargs[:payload][:content] == "later msg"
      end.returns("m")

      @poster.call([event(body: "later msg", sender_username: nil)])
    end

    # ---- media rendering ----

    test "appends resolved media URLs so Discord auto-embeds the image" do
      @client.expects(:execute_webhook).with do |kwargs|
        kwargs[:payload][:content].match?(%r{📎 photo\.jpg.*https://matrix\.redditspace\.com/_matrix/media}m)
      end.returns("m")

      @poster.call([event(
        kind: :media,
        body: "photo.jpg",
        sender_username: "nothnnn",
        media_url: "https://matrix.redditspace.com/_matrix/media/v3/download/matrix.redditspace.com/abc",
      )])
    end

    # ---- bookkeeping ----

    test "advances last_event_id after a successful post" do
      @client.expects(:execute_webhook).at_least_once.returns("m")

      @poster.call([event(event_id: "$evt_last")])

      assert_equal("$evt_last", Room.first.last_event_id)
    end

    test "re-raises when the client fails and leaves last_event_id unchanged" do
      room = Room.create!(matrix_room_id: ROOM_ID, last_event_id: "$prev")
      @client.expects(:execute_webhook).raises(Discord::ServerError, "503")

      assert_raises(Discord::ServerError) { @poster.call([event(event_id: "$new")]) }
      assert_equal("$prev", room.reload.last_event_id)
    end

    # ---- idempotency ----

    test "skips own events whose event_id is in the sent registry (Discord-originated echo)" do
      registry = mock("Registry")
      registry.expects(:sent_by_us?).with("$echo").returns(true)
      poster = Poster.new(client: @client, channel_index: @index, sent_registry: registry, sleeper: ->(s) {})
      @client.expects(:execute_webhook).never

      poster.call([event(event_id: "$echo", sender: OWN, body: "hi")])

      assert(PostedEvent.posted?("$echo"))
    end

    test "skips events already present in PostedEvent" do
      PostedEvent.record!(event_id: "$seen", room_id: ROOM_ID)
      @client.expects(:execute_webhook).never

      @poster.call([event(event_id: "$seen")])
    end

    test "records posted event_id so checkpoint rewinds don't cause duplicates" do
      @client.expects(:execute_webhook).at_least_once.returns("m")

      @poster.call([event(event_id: "$once")])
      # Simulate a checkpoint rewind: same batch comes back on next iteration.
      @poster.call([event(event_id: "$once")])

      assert_equal(1, PostedEvent.where(event_id: "$once").count)
    end

    # ---- rate limit retry ----

    test "retries on RateLimited and sleeps for retry_after_ms" do
      @client.expects(:execute_webhook).twice
        .raises(Discord::RateLimited.new("slow down", retry_after_ms: 2500))
        .then
        .returns("m")

      @poster.call([event])

      assert_equal([2.5], @sleeps)
    end

    test "gives up on persistent RateLimited after the attempt cap" do
      @client.expects(:execute_webhook)
        .at_least(Discord::Poster::RATE_LIMIT_MAX_ATTEMPTS)
        .raises(Discord::RateLimited.new("still", retry_after_ms: 100))

      assert_raises(Discord::RateLimited) { @poster.call([event]) }
    end

    # ---- webhook/channel recovery on 404 ----

    test "clears the stored webhook and retries when the first execute_webhook 404s" do
      room = Room.create!(
        matrix_room_id: ROOM_ID,
        discord_channel_id: CHANNEL_ID,
        discord_webhook_id: WEBHOOK_ID,
        discord_webhook_token: WEBHOOK_TOKEN,
        counterparty_username: "peer",
      )
      @client.expects(:execute_webhook).twice
        .raises(Discord::NotFound, "Unknown Webhook")
        .then
        .returns("msg-id")

      @poster.call([event])

      assert_nil(room.reload.discord_webhook_id)
      assert_nil(room.discord_webhook_token)
    end

    test "calls execute_webhook twice when the first attempt hits NotFound and the second succeeds" do
      Room.create!(
        matrix_room_id: ROOM_ID,
        discord_channel_id: CHANNEL_ID,
        discord_webhook_id: WEBHOOK_ID,
        discord_webhook_token: WEBHOOK_TOKEN,
        counterparty_username: "peer",
      )
      @client.expects(:execute_webhook).twice
        .raises(Discord::NotFound, "Unknown Webhook")
        .then
        .returns("msg-id")

      @poster.call([event])
    end

    # ---- content truncation + BadRequest handling ----

    test "truncates content longer than Discord's 2000-char cap" do
      @client.expects(:execute_webhook).with do |kwargs|
        body = kwargs[:payload][:content]
        body.length <= 2000 && body.end_with?("…[truncated]")
      end.returns("m")

      long = "a" * 3000
      @poster.call([event(body: long)])
    end

    test "records PostedEvent and skips forward on Discord::BadRequest instead of looping" do
      @client.expects(:execute_webhook).raises(Discord::BadRequest, "Invalid Form Body")

      @poster.call([event(event_id: "$bad")])

      # Event is marked posted so the next sync iteration doesn't replay it.
      assert(PostedEvent.posted?("$bad"))
    end

    # ---- terminated (hidden) rooms are silently filtered ----

    test "drops events for rooms the operator marked terminated" do
      Room.create!(matrix_room_id: ROOM_ID, terminated_at: 1.hour.ago)
      @client.expects(:execute_webhook).never

      @poster.call([event(body: "hi from beyond")])

      refute(PostedEvent.posted?("$default"))
    end

    # ---- archive auto-unarchive ----

    test "auto-unarchives a room when a new event arrives" do
      Room.create!(
        matrix_room_id: ROOM_ID,
        counterparty_matrix_id: PEER,
        counterparty_username: "testuser",
        archived_at: 1.day.ago,
      )
      @client.expects(:execute_webhook).at_least_once.returns("m")

      @poster.call([event(body: "ping")])

      refute_predicate(Room.first, :archived?)
    end

    # ---- permissions (Manage Webhooks missing on bot role) ----

    test "does not re-raise AuthError — swallows so the sync loop keeps advancing" do
      @index.expects(:ensure_webhook).at_least_once.raises(Discord::AuthError, "Missing Permissions")

      # No exception should bubble up.
      assert_nothing_raised { @poster.call([event(event_id: "$p1"), event(event_id: "$p2")]) }
    end

    test "records AuthError-blocked events as posted so they don't replay every tick" do
      @index.expects(:ensure_webhook).at_least_once.raises(Discord::AuthError, "Missing Permissions")

      @poster.call([event(event_id: "$p1")])

      assert(PostedEvent.posted?("$p1"))
    end

    test "sets the global permissions-blocked flag when AuthError hits" do
      AppConfig.set("discord_permissions_blocked_at", "")
      @index.expects(:ensure_webhook).at_least_once.raises(Discord::AuthError, "Missing Permissions")

      @poster.call([event])

      refute_empty(AppConfig.fetch("discord_permissions_blocked_at", ""))
    end

    test "clears the permissions-blocked flag after a successful post" do
      AppConfig.set("discord_permissions_blocked_at", "2026-04-17T12:00:00Z")
      @client.expects(:execute_webhook).at_least_once.returns("m")

      @poster.call([event])

      assert_equal("", AppConfig.fetch("discord_permissions_blocked_at", ""))
    end

    test "logs exactly one warn per batch even when every event hits AuthError" do
      logger = mock("Logger")
      logger.expects(:warn).once
      poster = Discord::Poster.new(
        client: @client,
        channel_index: @index,
        logger: logger,
        sleeper: ->(_) {},
      )
      @index.expects(:ensure_webhook).at_least_once.raises(Discord::AuthError, "Missing Permissions")

      poster.call([event(event_id: "$a"), event(event_id: "$b"), event(event_id: "$c")])
    end

    # ---- matrix_id fallback when username can't be resolved ----

    test "records counterparty_matrix_id even when sender_username is nil" do
      @client.expects(:execute_webhook).at_least_once.returns("m")

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
      @client.expects(:execute_webhook).at_least_once.returns("m")

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
      @client.expects(:execute_webhook).at_least_once.returns("m")
      @client.expects(:rename_channel).with(channel_id: "chan_123", name: "dm-nothnnn").returns(:ok)

      @poster.call([event(body: "hi", sender_username: "nothnnn")])

      assert_equal("nothnnn", room.reload.counterparty_username)
    end

    test "resolves the webhook via the channel index for each event" do
      @index.unstub(:ensure_webhook)
      @index.expects(:ensure_webhook).with(has_entry(:room, instance_of(Room))).returns([WEBHOOK_ID, WEBHOOK_TOKEN])
      @client.expects(:execute_webhook).at_least_once.returns("m")

      @poster.call([event])
    end

    private

    def event( # rubocop:disable Metrics/ParameterLists
      event_id: "$default",
      sender: PEER,
      body: "hello",
      sender_username: nil,
      sender_avatar_url: nil,
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
        sender_avatar_url: sender_avatar_url,
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
