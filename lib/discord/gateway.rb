# frozen_string_literal: true

require "concurrent"
require "json"
require "websocket-client-simple"

module Discord
  # Thin Discord Gateway v10 client scoped to what Phase 2 needs:
  #   - IDENTIFY with intents for GUILD_MESSAGES + MESSAGE_CONTENT
  #   - heartbeat on the server's cadence
  #   - dispatch MESSAGE_CREATE payloads to the injected handler
  #
  # Deliberately narrow: no voice, no sharding, no resume (a reconnect
  # just re-IDENTIFYs and re-pulls recent messages via REST if needed).
  # Reddit Chat's DM volume is low enough that the simple loop is fine.
  class Gateway
    URL = "wss://gateway.discord.gg/?v=10&encoding=json"

    OP_DISPATCH   = 0
    OP_HEARTBEAT  = 1
    OP_IDENTIFY   = 2
    OP_HELLO      = 10
    OP_HEARTBEAT_ACK = 11

    # Close codes that are a normal part of Discord's lifecycle: 1000
    # (normal closure) and 1001 (server going away — Discord routinely
    # asks clients to reconnect for load-balancing). `nil` covers the
    # network-level drop case where no close frame reached us. None of
    # these warrant paging #app-status; the reconnect loop handles them.
    BENIGN_CLOSE_CODES = [nil, 1000, 1001].freeze

    # Bitfield: GUILDS (1<<0) | GUILD_MESSAGES (1<<9) | MESSAGE_CONTENT (1<<15).
    DEFAULT_INTENTS = (1 << 0) | (1 << 9) | (1 << 15)

    def initialize(bot_token:, on_message_create:, on_interaction_create: nil, journal: nil, intents: DEFAULT_INTENTS, url: URL)
      @bot_token = bot_token
      @on_message_create = on_message_create
      @on_interaction_create = on_interaction_create
      @journal = journal
      @intents = intents
      @url = url
      @stopped = false
      @last_sequence = nil
      @heartbeat = nil
      @socket = nil
      @connected_once = false
    end

    def run(stop_signal: -> { false })
      until stop_signal.call || @stopped
        begin
          run_once(stop_signal)
        rescue StandardError => e
          @journal&.warn("Discord gateway crashed: #{e.class}: #{e.message}", source: "gateway")
          sleep(2) unless stop_signal.call
        end
      end
    end

    def stop!
      @stopped = true
      stop_heartbeat!
      @socket&.close
    end

    def stopping?
      @stopped
    end

    # The callback methods below (`dispatch_frame`, `handle_frame`,
    # `stop_heartbeat!`, `journal_warn`) have to stay public:
    # WebSocket::Client::Simple invokes its `on` blocks with an explicit
    # receiver, and private methods in Ruby raise `NoMethodError` for
    # explicit-receiver calls — the error would get swallowed in the
    # websocket thread.

    # websocket-client-simple emits every decoded frame through :message —
    # text, binary, close, ping, pong. We only want to JSON-parse :text;
    # close frames carry a UTF-8 reason that would otherwise reach
    # handle_frame and trip the JSON parser (seen in the wild as "bad
    # frame: unexpected character: 'Discord'" when Discord closed with
    # an error reason like "Discord WebSocket: …").
    def dispatch_frame(msg)
      case msg.type
      when :text then handle_frame(msg.data)
      when :close then log_close(msg)
      end
    end

    def handle_frame(raw)
      payload = JSON.parse(raw)
      @last_sequence = payload["s"] if payload["s"]

      case payload["op"]
      when OP_HELLO then on_hello(payload)
      when OP_DISPATCH then on_dispatch(payload)
      when OP_HEARTBEAT_ACK then nil
      end
    rescue JSON::ParserError => e
      journal_warn("bad frame: #{e.message} (payload=#{raw.to_s[0, 80].inspect})")
    rescue StandardError => e
      # Any bug in on_hello/on_dispatch/handlers must not kill the
      # websocket thread silently. Log it and keep the socket alive.
      journal_warn("frame handler crashed: #{e.class}: #{e.message}")
    end

    def log_close(msg)
      code = msg.respond_to?(:code) ? msg.code : nil
      reason = msg.data.to_s
      text = "socket close frame: code=#{code.inspect} reason=#{reason.inspect}"
      if BENIGN_CLOSE_CODES.include?(code)
        @journal&.info(text, source: "gateway")
      else
        @journal&.warn(text, source: "gateway")
      end
    end

    def stop_heartbeat!
      @heartbeat&.shutdown
      @heartbeat = nil
    end

    def journal_warn(message)
      @journal&.warn(message, source: "gateway")
    end

    private

    def run_once(stop_signal)
      gateway = self

      @socket = WebSocket::Client::Simple.connect(@url)

      @socket.on(:message) do |msg|
        gateway.dispatch_frame(msg)
      end
      @socket.on(:close) do
        gateway.stop_heartbeat!
      end
      @socket.on(:error) do |e|
        # Closing the socket from stop! races with the reader thread and
        # surfaces here as IOError("stream closed in another thread"). That's
        # how shutdown is supposed to end — stay silent on the way out.
        next if gateway.stopping?

        gateway.journal_warn("socket error: #{e.message}")
      end

      # First connect piggybacks on Bridge::Application's "Bridge online …
      # discord gateway up" notice — no need to double-log. Reconnects
      # after a crash are the informative transition, so call those out.
      @journal&.info("Discord gateway reconnected", source: "gateway") if @connected_once
      @connected_once = true

      # Block the caller thread until the supervisor asks us to stop.
      sleep(0.2) until @stopped || stop_signal.call
      @socket.close
    end

    def on_hello(payload)
      interval_ms = payload.dig("d", "heartbeat_interval") || 41_250
      start_heartbeat(interval_ms)
      send_frame(opcode: OP_IDENTIFY, data: identify_payload)
    end

    def on_dispatch(payload)
      case payload["t"]
      when "MESSAGE_CREATE"
        @on_message_create.call(payload["d"])
      when "INTERACTION_CREATE"
        @on_interaction_create&.call(payload["d"])
      end
    end

    # Fires once every `interval_ms` until `stop_heartbeat!` shuts the task
    # down. TimerTask owns the thread + scheduling — we just provide the
    # tick body. The first tick is deferred by `execution_interval` (same
    # cadence as Discord expects), so the IDENTIFY frame lands before any
    # heartbeat.
    def start_heartbeat(interval_ms)
      @heartbeat = Concurrent::TimerTask.execute(execution_interval: interval_ms / 1000.0) do
        send_frame(opcode: OP_HEARTBEAT, data: @last_sequence) unless @stopped
      end
    end

    def send_frame(opcode:, data:)
      return unless @socket

      @socket.send(JSON.generate(op: opcode, d: data))
    rescue StandardError => e
      journal_warn("send failed: #{e.class}: #{e.message}")
    end

    def identify_payload
      {
        token: @bot_token,
        intents: @intents,
        properties: {
          "$os" => "linux",
          "$browser" => "reddit_chat_bridge",
          "$device" => "reddit_chat_bridge",
        },
      }
    end
  end
end
