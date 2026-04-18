# frozen_string_literal: true

require "test_helper"
require "matrix/invite_handler"

module Matrix
  class InviteHandlerTest < ActiveSupport::TestCase
    OWN = "@t2_me:reddit.com"
    INVITER = "@t2_testuser:reddit.com"
    ROOM = "!stranger:reddit.com"

    setup do
      @handler = InviteHandler.new(own_user_id: OWN)
    end

    test "creates a MessageRequest per invite with inviter details extracted from member state" do
      body = build_sync_body(
        member_inviter: member(INVITER, displayname: "testuser", membership: "join"),
        member_self:    member(OWN, membership: "invite", sender: INVITER),
      )

      @handler.call(body)

      req = MessageRequest.find_by!(matrix_room_id: ROOM)

      assert_equal(INVITER, req.inviter_matrix_id)
      assert_equal("testuser", req.inviter_username)
      assert_predicate(req, :pending?)
    end

    test "prefers the Reddit profile username over displayname" do
      body = build_sync_body(
        member_inviter: member(INVITER, displayname: "generic", reddit_username: "testuser", membership: "join"),
        member_self:    member(OWN, membership: "invite", sender: INVITER),
      )

      @handler.call(body)

      assert_equal("testuser", MessageRequest.find_by!(matrix_room_id: ROOM).inviter_username)
    end

    test "extracts preview_body from an m.room.message event in invite_state" do
      body = build_sync_body(
        member_inviter: member(INVITER, displayname: "testuser", membership: "join"),
        member_self:    member(OWN, membership: "invite", sender: INVITER),
        extra_events:   [message_event("hey! want to collab?", INVITER)],
      )

      @handler.call(body)

      assert_equal("hey! want to collab?", MessageRequest.find_by!(matrix_room_id: ROOM).preview_body)
    end

    test "resolves avatar via the media resolver when the inviter has an mxc avatar" do
      resolver = mock("MediaResolver")
      resolver.expects(:resolve).with("mxc://server/x").returns("https://cdn/x.png")
      handler = InviteHandler.new(own_user_id: OWN, media_resolver: resolver)
      body = build_sync_body(
        member_inviter: member(INVITER, displayname: "testuser", avatar_mxc: "mxc://server/x", membership: "join"),
        member_self:    member(OWN, membership: "invite", sender: INVITER),
      )

      handler.call(body)

      assert_equal("https://cdn/x.png", MessageRequest.find_by!(matrix_room_id: ROOM).inviter_avatar_url)
    end

    test "is idempotent — re-processing the same invite doesn't duplicate" do
      body = build_sync_body(
        member_inviter: member(INVITER, displayname: "testuser", membership: "join"),
        member_self:    member(OWN, membership: "invite", sender: INVITER),
      )

      @handler.call(body)
      @handler.call(body)

      assert_equal(1, MessageRequest.where(matrix_room_id: ROOM).count)
    end

    test "invokes the notifier with the created MessageRequest" do
      notifier = mock("Notifier")
      notifier.expects(:notify!).with(instance_of(MessageRequest))
      handler = InviteHandler.new(own_user_id: OWN, notifier: notifier)
      body = build_sync_body(
        member_inviter: member(INVITER, displayname: "testuser", membership: "join"),
        member_self:    member(OWN, membership: "invite", sender: INVITER),
      )

      handler.call(body)
    end

    test "does not re-notify for an invite that's already been seen" do
      MessageRequest.create!(matrix_room_id: ROOM, inviter_matrix_id: INVITER)
      notifier = mock("Notifier")
      notifier.expects(:notify!).never
      handler = InviteHandler.new(own_user_id: OWN, notifier: notifier)
      body = build_sync_body(
        member_inviter: member(INVITER, membership: "join"),
        member_self:    member(OWN, membership: "invite", sender: INVITER),
      )

      handler.call(body)
    end

    test "gracefully handles a malformed invite (missing member events) without raising" do
      body = build_sync_body_bare

      assert_nothing_raised { @handler.call(body) }
      req = MessageRequest.find_by!(matrix_room_id: ROOM)

      assert_nil(req.inviter_matrix_id)
      assert_nil(req.inviter_username)
    end

    private

    def build_sync_body(member_inviter:, member_self:, extra_events: [])
      {
        "rooms" => {
          "invite" => {
            ROOM => {
              "invite_state" => { "events" => [member_inviter, member_self, *extra_events] },
            },
          },
        },
      }
    end

    def build_sync_body_bare
      {
        "rooms" => {
          "invite" => {
            ROOM => { "invite_state" => { "events" => [] } },
          },
        },
      }
    end

    def member(user_id, membership: "join", displayname: nil, reddit_username: nil, avatar_mxc: nil, sender: user_id) # rubocop:disable Metrics/ParameterLists
      content = { "membership" => membership }
      content["displayname"] = displayname if displayname
      content["avatar_url"] = avatar_mxc if avatar_mxc

      unsigned = {}
      unsigned["m.relations"] = { "com.reddit.profile" => { "username" => reddit_username } } if reddit_username

      {
        "type" => "m.room.member",
        "state_key" => user_id,
        "sender" => sender,
        "content" => content,
        "unsigned" => unsigned,
      }
    end

    def message_event(body, sender)
      {
        "type" => "m.room.message",
        "sender" => sender,
        "content" => { "msgtype" => "m.text", "body" => body },
      }
    end
  end
end
