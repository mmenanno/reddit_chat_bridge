# frozen_string_literal: true

require "test_helper"
require "matrix/event_normalizer"

module Matrix
  class EventNormalizerTest < ActiveSupport::TestCase
    OWN = "@t2_22jl0cs4s6:reddit.com"
    PEER = "@t2_5jp4q:reddit.com"
    REDDIT_SYSTEM = "@t2_1qwk:reddit.com"

    def setup
      super
      @normalizer = EventNormalizer.new(own_user_id: OWN)
    end

    test "returns an empty array when the sync body has no rooms key at all" do
      assert_empty(@normalizer.normalize({}))
    end

    test "returns an empty array when the rooms hash is present but empty" do
      assert_empty(@normalizer.normalize({ "rooms" => {} }))
    end

    test "returns an empty array when there are no joined rooms" do
      assert_empty(@normalizer.normalize({ "rooms" => { "join" => {} } }))
    end

    test "emits one NormalizedEvent per m.room.message in the timeline" do
      body = sync(join: {
        "!room1:reddit.com" => room(
          timeline: [chat_message(event_id: "$a", sender: PEER, body: "hello")],
        ),
      })

      result = @normalizer.normalize(body)

      assert_equal(1, result.size)
      assert_equal("$a", result.first.event_id)
    end

    test "propagates room_id and body" do
      body = sync(join: {
        "!room1:reddit.com" => room(timeline: [chat_message(sender: PEER, body: "hi")]),
      })

      event = @normalizer.normalize(body).first

      assert_equal("!room1:reddit.com", event.room_id)
      assert_equal("hi", event.body)
    end

    test "propagates sender and timestamp" do
      body = sync(join: {
        "!room1:reddit.com" => room(
          timeline: [chat_message(sender: PEER, body: "hi", timestamp: 1_700_000_000_000)],
        ),
      })

      event = @normalizer.normalize(body).first

      assert_equal(PEER, event.sender)
      assert_equal(1_700_000_000_000, event.origin_server_ts)
    end

    test "filters non-message timeline entries like com.reddit.profile" do
      body = sync(join: {
        "!room1:reddit.com" => room(
          timeline: [
            { "type" => "com.reddit.profile", "event_id" => "$p", "sender" => PEER, "content" => {} },
            chat_message(event_id: "$m", sender: PEER, body: "real"),
            { "type" => "m.room.power_levels", "event_id" => "$pl", "sender" => PEER, "content" => {} },
          ],
        ),
      })

      result = @normalizer.normalize(body)

      assert_equal(["$m"], result.map(&:event_id))
    end

    test "is_own? is true when the sender matches the configured user" do
      body = sync(join: {
        "!room1:reddit.com" => room(timeline: [chat_message(sender: OWN, body: "self")]),
      })

      assert_predicate(@normalizer.normalize(body).first, :own?)
    end

    test "is_own? is false for messages from other accounts" do
      body = sync(join: {
        "!room1:reddit.com" => room(timeline: [chat_message(sender: PEER, body: "from peer")]),
      })

      refute_predicate(@normalizer.normalize(body).first, :own?)
    end

    test "is_system? is true for messages from @t2_1qwk (Reddit redactor bot)" do
      body = sync(join: {
        "!room1:reddit.com" => room(timeline: [chat_message(sender: REDDIT_SYSTEM, body: "mod notice")]),
      })

      assert_predicate(@normalizer.normalize(body).first, :system?)
    end

    test "sender_username prefers the Reddit profile username from member state" do
      body = sync(join: {
        "!room1:reddit.com" => room(
          state: [
            member(user_id: PEER, displayname: "ignored", reddit_username: "testuser"),
          ],
          timeline: [chat_message(sender: PEER, body: "hi")],
        ),
      })

      assert_equal("testuser", @normalizer.normalize(body).first.sender_username)
    end

    test "sender_username falls back to content.displayname when no Reddit profile relation" do
      body = sync(join: {
        "!room1:reddit.com" => room(
          state: [member(user_id: PEER, displayname: "testuser", reddit_username: nil)],
          timeline: [chat_message(sender: PEER, body: "hi")],
        ),
      })

      assert_equal("testuser", @normalizer.normalize(body).first.sender_username)
    end

    test "sender_username is nil when no member state is available" do
      body = sync(join: {
        "!room1:reddit.com" => room(timeline: [chat_message(sender: PEER, body: "hi")]),
      })

      assert_nil(@normalizer.normalize(body).first.sender_username)
    end

    test "resolves username from member events that arrive in the timeline itself" do
      body = sync(join: {
        "!room1:reddit.com" => room(
          timeline: [
            member(user_id: PEER, displayname: nil, reddit_username: "testuser"),
            chat_message(sender: PEER, body: "hi"),
          ],
        ),
      })

      assert_equal("testuser", @normalizer.normalize(body).first.sender_username)
    end

    test "emits events across multiple rooms, stamped with the correct room_id" do
      body = sync(join: {
        "!one:reddit.com" => room(timeline: [chat_message(event_id: "$1", sender: PEER, body: "first")]),
        "!two:reddit.com" => room(timeline: [chat_message(event_id: "$2", sender: PEER, body: "second")]),
      })

      result = @normalizer.normalize(body)

      assert_equal(["!one:reddit.com", "!two:reddit.com"].sort, result.map(&:room_id).sort)
    end

    test "kind is :message for regular chat messages" do
      body = sync(join: {
        "!room1:reddit.com" => room(timeline: [chat_message(sender: PEER, body: "hi")]),
      })

      assert_equal(:message, @normalizer.normalize(body).first.kind)
    end

    # ---- media resolution ----

    test "resolves m.image events through the media resolver" do
      resolver = mock("Resolver")
      resolver.expects(:resolve).with("mxc://matrix.redditspace.com/abc").returns("https://cdn/x.jpg")
      normalizer = EventNormalizer.new(own_user_id: OWN, media_resolver: resolver)
      body = sync(join: {
        "!room1:reddit.com" => room(timeline: [image_message("photo.jpg", "mxc://matrix.redditspace.com/abc")]),
      })

      event = normalizer.normalize(body).first

      assert_equal("https://cdn/x.jpg", event.media_url)
    end

    test "marks media events with kind=:media and media? predicate" do
      resolver = mock("Resolver")
      resolver.stubs(:resolve).returns("https://cdn/x.jpg")
      normalizer = EventNormalizer.new(own_user_id: OWN, media_resolver: resolver)
      body = sync(join: {
        "!r:reddit.com" => room(timeline: [image_message("photo.jpg", "mxc://server/id")]),
      })

      event = normalizer.normalize(body).first

      assert_equal(:media, event.kind)
      assert_predicate(event, :media?)
    end

    test "leaves the event as a regular :message when no resolver is configured" do
      body = sync(join: {
        "!r:reddit.com" => room(timeline: [image_message("a.jpg", "mxc://server/id")]),
      })

      event = @normalizer.normalize(body).first

      assert_equal(:message, event.kind)
      refute_predicate(event, :media?)
    end

    private

    def image_message(filename, mxc_url, event_id: "$img", sender: PEER)
      {
        "type" => "m.room.message",
        "event_id" => event_id,
        "sender" => sender,
        "origin_server_ts" => 1_776_400_000_000,
        "content" => {
          "msgtype" => "m.image",
          "body" => filename,
          "url" => mxc_url,
          "info" => { "mimetype" => "image/jpeg" },
        },
      }
    end

    def sync(join: {}, invite: {})
      { "rooms" => { "join" => join, "invite" => invite } }
    end

    def room(timeline: [], state: [])
      { "timeline" => { "events" => timeline }, "state" => { "events" => state } }
    end

    def chat_message(sender:, body:, event_id: "$default", timestamp: 1_776_400_000_000)
      {
        "type" => "m.room.message",
        "event_id" => event_id,
        "sender" => sender,
        "origin_server_ts" => timestamp,
        "content" => { "msgtype" => "m.text", "body" => body },
      }
    end

    def member(user_id:, displayname:, reddit_username:)
      content = {}
      content["displayname"] = displayname if displayname

      unsigned = {}
      unsigned["m.relations"] = { "com.reddit.profile" => { "username" => reddit_username } } if reddit_username

      {
        "type" => "m.room.member",
        "event_id" => "$member_#{user_id}",
        "sender" => user_id,
        "state_key" => user_id,
        "content" => content,
        "unsigned" => unsigned,
      }
    end
  end
end
