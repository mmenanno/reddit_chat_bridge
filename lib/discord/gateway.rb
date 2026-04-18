# frozen_string_literal: true

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

    # Bitfield: GUILDS (1<<0) | GUILD_MESSAGES (1<<9) | MESSAGE_CONTENT (1<<15).
    DEFAULT_INTENTS = (1 << 0) | (1 << 9) | (1 << 15)

    def initialize(bot_token:, on_message_create:, journal: nil, intents: DEFAULT_INTENTS, url: URL)
      @bot_token = bot_token
      @on_message_create = on_message_create
      @journal = journal
      @intents = intents
      @url = url
      @stopped = false
      @last_sequence = nil
      @heartbeat_thread = nil
      @socket = nil
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
      @heartbeat_thread&.kill
      @socket&.close
    end

    private

    def run_once(stop_signal)
      gateway = self

      @socket = WebSocket::Client::Simple.connect(@url)

      @socket.on(:message) do |msg|
        gateway.handle_frame(msg.data)
      end
      @socket.on(:close) do
        gateway.stop_heartbeat!
      end
      @socket.on(:error) do |e|
        gateway.journal_warn("socket error: #{e.message}")
      end

      # Block the caller thread until the supervisor asks us to stop.
      sleep(0.2) until @stopped || stop_signal.call
      @socket.close
    end

    # ---- callbacks exposed to the WebSocket::Client::Simple handlers ----

    def handle_frame(raw)
      payload = JSON.parse(raw)
      @last_sequence = payload["s"] if payload["s"]

      case payload["op"]
      when OP_HELLO then on_hello(payload)
      when OP_DISPATCH then on_dispatch(payload)
      when OP_HEARTBEAT_ACK then nil
      end
    rescue JSON::ParserError => e
      journal_warn("bad frame: #{e.message}")
    end

    def on_hello(payload)
      interval_ms = payload.dig("d", "heartbeat_interval") || 41_250
      start_heartbeat(interval_ms)
      send_frame(opcode: OP_IDENTIFY, data: identify_payload)
    end

    def on_dispatch(payload)
      return unless payload["t"] == "MESSAGE_CREATE"

      @on_message_create.call(payload["d"])
    end

    def start_heartbeat(interval_ms)
      @heartbeat_thread = Thread.new do # rubocop:disable ThreadSafety/NewThread
        Thread.current.name = "discord-gateway-heartbeat"
        loop do
          sleep(interval_ms / 1000.0)
          break if @stopped

          send_frame(opcode: OP_HEARTBEAT, data: @last_sequence)
        end
      end
    end

    def stop_heartbeat!
      @heartbeat_thread&.kill
      @heartbeat_thread = nil
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

    def journal_warn(message)
      @journal&.warn(message, source: "gateway")
    end
  end
end
