# frozen_string_literal: true

require "test_helper"
require "discord/message_component_router"

module Discord
  class MessageComponentRouterTest < ActiveSupport::TestCase
    setup do
      @admin = mock("AdminActions")
      @notifier = mock("Notifier")
      @router = MessageComponentRouter.new(admin_actions: @admin, notifier: @notifier)
    end

    test "routes mr:approve:<id> to approve_message_request! and returns an UPDATE_MESSAGE response" do
      request = MessageRequest.create!(matrix_room_id: "!r:reddit.com")
      @admin.expects(:approve_message_request!).with(id: request.id).returns(request)
      @notifier.expects(:resolution_payload).with(request).returns(embeds: [], components: [])

      response = @router.dispatch(click("mr:approve:#{request.id}"))

      assert_equal(7, response[:type])
      assert_equal({ embeds: [], components: [] }, response[:data])
    end

    test "routes mr:decline:<id> to decline_message_request!" do
      request = MessageRequest.create!(matrix_room_id: "!r:reddit.com")
      @admin.expects(:decline_message_request!).with(id: request.id).returns(request)
      @notifier.expects(:resolution_payload).with(request).returns(embeds: [], components: [])

      response = @router.dispatch(click("mr:decline:#{request.id}"))

      assert_equal(7, response[:type])
    end

    test "returns an ephemeral error for unknown custom_ids" do
      response = @router.dispatch(click("mystery:foo"))

      assert_equal(4, response[:type])
      assert_equal(64, response[:data][:flags])
      assert_match(/Unknown interaction/, response[:data][:content])
    end

    test "catches handler exceptions and surfaces them as ephemeral replies" do
      @admin.expects(:approve_message_request!).raises(RuntimeError, "nope")

      response = @router.dispatch(click("mr:approve:42"))

      assert_equal(4, response[:type])
      assert_match(/RuntimeError.*nope/, response[:data][:content])
    end

    # ---- /unarchive button family ----

    test "unarchive:select:<room> rewrites the message into a confirm prompt" do
      room = Room.create!(matrix_room_id: "!a:reddit.com", counterparty_username: "alpha", archived_at: 1.day.ago)

      response = @router.dispatch(click("unarchive:select:#{room.id}"))

      assert_equal(7, response[:type])
      assert_match(/Confirm.*alpha/i, response[:data][:embeds].first[:title])
      buttons = response[:data][:components].first[:components]

      assert_equal("unarchive:confirm:#{room.id}", buttons.first[:custom_id])
    end

    test "unarchive:confirm:<room> calls Admin::Actions and rewrites with success state" do
      room = Room.create!(matrix_room_id: "!a:reddit.com", counterparty_username: "alpha", archived_at: 1.day.ago)
      @admin.expects(:unarchive_room!).with(matrix_room_id: room.matrix_room_id, backfill: true)

      response = @router.dispatch(click("unarchive:confirm:#{room.id}"))

      assert_equal(7, response[:type])
      assert_match(/Unarchived alpha/, response[:data][:embeds].first[:title])
      assert_empty(response[:data][:components])
    end

    test "unarchive:cancel rewrites the message into a cancellation note" do
      response = @router.dispatch(click("unarchive:cancel:42"))

      assert_equal(7, response[:type])
      assert_match(/cancelled/i, response[:data][:embeds].first[:title])
      assert_empty(response[:data][:components])
    end

    test "unarchive:confirm with a missing room returns a friendly error embed" do
      @admin.expects(:unarchive_room!).never

      response = @router.dispatch(click("unarchive:confirm:99999"))

      assert_match(/Room is gone/, response[:data][:embeds].first[:description])
    end

    # ---- /restore button family ----

    test "restore:confirm:<room> calls Admin::Actions and rewrites with success state" do
      room = Room.create!(matrix_room_id: "!a:reddit.com", counterparty_username: "ghosted", terminated_at: 1.day.ago)
      @admin.expects(:restore_chat!).with(matrix_room_id: room.matrix_room_id)

      response = @router.dispatch(click("restore:confirm:#{room.id}"))

      assert_equal(7, response[:type])
      assert_match(/Restored ghosted/, response[:data][:embeds].first[:title])
    end

    test "restore:cancel rewrites the message into a cancellation note" do
      response = @router.dispatch(click("restore:cancel:42"))

      assert_match(/cancelled/i, response[:data][:embeds].first[:title])
    end

    private

    def click(custom_id)
      { "type" => 3, "data" => { "custom_id" => custom_id, "component_type" => 2 } }
    end
  end
end
