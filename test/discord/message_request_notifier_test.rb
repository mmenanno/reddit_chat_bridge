# frozen_string_literal: true

require "test_helper"
require "discord/message_request_notifier"

module Discord
  class MessageRequestNotifierTest < ActiveSupport::TestCase
    CHANNEL = "999999999999"

    def setup
      super
      @client = mock("DiscordClient")
    end

    test "posts an embed with Approve/Decline buttons whose custom_ids encode the request id" do
      notifier = MessageRequestNotifier.new(client: @client, channel_id: CHANNEL)
      request = MessageRequest.create!(
        matrix_room_id: "!r:reddit.com",
        inviter_username: "testuser",
        inviter_matrix_id: "@t2_testuser:reddit.com",
      )

      @client.expects(:create_message).with do |kwargs|
        payload = kwargs[:payload]
        buttons = payload[:components].first[:components]
        kwargs[:channel_id] == CHANNEL &&
          payload[:embeds].first[:title].include?("testuser") &&
          buttons.map { |b| b[:custom_id] } == ["mr:approve:#{request.id}", "mr:decline:#{request.id}"]
      end.returns("id" => "msg_1", "channel_id" => CHANNEL)

      notifier.notify!(request)

      assert_equal("msg_1", request.reload.discord_message_id)
      assert_equal(CHANNEL, request.discord_channel_id)
    end

    test "includes the preview body as a quoted block when present" do
      notifier = MessageRequestNotifier.new(client: @client, channel_id: CHANNEL)
      request = MessageRequest.create!(
        matrix_room_id: "!r:reddit.com",
        inviter_username: "testuser",
        preview_body: "hey! want to collab on a project?",
      )

      @client.expects(:create_message).with do |kwargs|
        description = kwargs[:payload][:embeds].first[:description]
        description.include?("> hey! want to collab on a project?")
      end.returns("id" => "msg_1")

      notifier.notify!(request)
    end

    test "adds the inviter avatar as an embed thumbnail when present" do
      notifier = MessageRequestNotifier.new(client: @client, channel_id: CHANNEL)
      request = MessageRequest.create!(
        matrix_room_id: "!r:reddit.com",
        inviter_avatar_url: "https://cdn/av.png",
      )

      @client.expects(:create_message).with do |kwargs|
        kwargs[:payload][:embeds].first[:thumbnail] == { url: "https://cdn/av.png" }
      end.returns("id" => "m")

      notifier.notify!(request)
    end

    test "falls back to the fallback channel id when the primary is empty" do
      notifier = MessageRequestNotifier.new(client: @client, channel_id: "", fallback_channel_id: "fb_1")
      request = MessageRequest.create!(matrix_room_id: "!r:reddit.com")
      @client.expects(:create_message).with(has_entry(:channel_id, "fb_1")).returns("id" => "m")

      notifier.notify!(request)
    end

    test "no-ops when no channel is configured anywhere" do
      notifier = MessageRequestNotifier.new(client: @client, channel_id: nil)
      request = MessageRequest.create!(matrix_room_id: "!r:reddit.com")
      @client.expects(:create_message).never

      notifier.notify!(request)
    end

    test "resolution_payload produces a button-less embed with a status line" do
      notifier = MessageRequestNotifier.new(client: @client, channel_id: CHANNEL)
      request = MessageRequest.create!(matrix_room_id: "!r:reddit.com", inviter_username: "testuser")
      request.resolve!(decision: MessageRequest::APPROVED, at: Time.utc(2026, 4, 18, 12, 0))

      payload = notifier.resolution_payload(request)

      assert_empty(payload[:components])
      status_field = payload[:embeds].first[:fields].find { |f| f[:name] == "Status" }

      assert_match(/Approved/, status_field[:value])
    end
  end
end
