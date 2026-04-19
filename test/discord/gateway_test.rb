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

    test "benign close (1000 normal) is silent — routine reconnects don't need operator attention" do
      @journal.expects(:info).never
      @journal.expects(:warn).never

      @gateway.dispatch_frame(CloseMsg.new(:close, "Normal closure.", 1000))
    end

    test "benign close (1001 going away) is silent — Discord load-balancer routinely asks clients to reconnect" do
      @journal.expects(:info).never
      @journal.expects(:warn).never

      @gateway.dispatch_frame(CloseMsg.new(:close, "Discord WebSocket requesting client reconnect.", 1001))
    end

    test "missing close code is treated as benign — network-level drop with no server-sent code" do
      @journal.expects(:info).never
      @journal.expects(:warn).never

      @gateway.dispatch_frame(CloseMsg.new(:close, "", nil))
    end

    test "protocol-error close (4000-range) is still a warn so the operator sees it in #app-status" do
      @journal.expects(:warn).with(regexp_matches(/code=4004/), source: "gateway")

      @gateway.dispatch_frame(CloseMsg.new(:close, "Authentication failed.", 4004))
    end

    # ---- reconnect loop ----

    # Minimal fake that records callbacks so the test can trigger them
    # exactly as websocket-client-simple would. `close` is a no-op — the
    # real class's close invokes the :close callback via the WS thread,
    # but we drive that callback from the test directly.
    class FakeSocket
      attr_reader :callbacks

      def initialize
        @callbacks = {}
        @closed = false
      end

      def on(event, &block)
        @callbacks[event] = block
      end

      def close
        @closed = true
      end

      def closed?
        @closed
      end

      def fire(event, *)
        @callbacks[event]&.call(*)
      end
    end

    test "run_once returns when the socket closes so the outer loop reconnects" do
      sockets = Array.new(2) { FakeSocket.new }
      factory_calls = 0
      factory = lambda { |_url|
        socket = sockets[factory_calls]
        factory_calls += 1
        socket
      }

      @journal.stubs(:info)
      @journal.stubs(:warn)

      gateway = Discord::Gateway.new(
        bot_token: "tok",
        on_message_create: ->(_) {},
        journal: @journal,
        socket_factory: factory,
      )

      # Need a real thread to run the blocking `run` loop while the test
      # drives the close callback. A thread pool is wrong here — this is
      # a blocking run_forever, same shape as the supervisor thread.
      worker = Thread.new { gateway.run(stop_signal: -> { false }) } # rubocop:disable ThreadSafety/NewThread

      # Wait for the first connect to wire up its on(:close) callback.
      Timeout.timeout(2) { sleep(0.01) until sockets[0].callbacks[:close] }

      # Discord sends a close — this should cause run_once to return and
      # the outer run loop to connect a second socket.
      sockets[0].fire(:close)

      Timeout.timeout(2) { sleep(0.01) until sockets[1].callbacks[:close] }

      assert_equal(2, factory_calls, "gateway must reconnect after a server-initiated close")
      assert_predicate(sockets[0], :closed?, "old socket should be closed when run_once exits")

      gateway.stop!
      worker.join(2)
    end
  end
end
