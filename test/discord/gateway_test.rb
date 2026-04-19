# frozen_string_literal: true

require "test_helper"
require "discord/gateway"

module Discord
  class GatewayTest < ActiveSupport::TestCase
    CloseMsg = Struct.new(:type, :data, :code)

    setup do
      @journal = mock("Journal")
      @gateway = Discord::Gateway.new(
        bot_token: "tok",
        on_message_create: ->(_) {},
        journal: @journal,
      )
    end

    test "normal close (1000) is journaled at info — Discord load-balancer reconnects aren't an #app-status page" do
      @journal.expects(:info).with(regexp_matches(/code=1000/), source: "gateway")

      @gateway.dispatch_frame(CloseMsg.new(:close, "Normal closure.", 1000))
    end

    test "going-away close (1001) is journaled at info — Discord routinely asks clients to reconnect" do
      @journal.expects(:info).with(
        regexp_matches(/code=1001.*Discord WebSocket requesting client reconnect/),
        source: "gateway",
      )

      @gateway.dispatch_frame(CloseMsg.new(:close, "Discord WebSocket requesting client reconnect.", 1001))
    end

    test "missing close code is treated as benign (network-level drop — server never sent a code)" do
      @journal.expects(:info).with(regexp_matches(/code=nil/), source: "gateway")

      @gateway.dispatch_frame(CloseMsg.new(:close, "", nil))
    end

    test "protocol-error close (4000-range) is still a warn so the operator sees it in #app-status" do
      @journal.expects(:warn).with(regexp_matches(/code=4004/), source: "gateway")

      @gateway.dispatch_frame(CloseMsg.new(:close, "Authentication failed.", 4004))
    end
  end
end
