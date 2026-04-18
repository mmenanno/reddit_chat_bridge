# frozen_string_literal: true

require "test_helper"
require "discord/message_component_router"

module Discord
  class MessageComponentRouterTest < ActiveSupport::TestCase
    def setup
      super
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

    private

    def click(custom_id)
      { "type" => 3, "data" => { "custom_id" => custom_id, "component_type" => 2 } }
    end
  end
end
