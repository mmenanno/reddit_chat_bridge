# frozen_string_literal: true

module Discord
  # Orchestrates gateway-delivered INTERACTION_CREATE payloads within
  # Discord's 3-second ACK deadline.
  #
  # Flow:
  #   1. Immediately ACK with a *deferred* response (types 5 or 6) so
  #      Discord stops the countdown — this is the only step that has to
  #      beat the 3s window.
  #   2. Hand the real work (router dispatch, which may make a blocking
  #      Matrix round-trip) to the injected scheduler — `Thread.new` in
  #      production, an inline scheduler in tests.
  #   3. When the work finishes, PATCH @original via the interaction
  #      webhook. That endpoint's 15-minute follow-up window is generous
  #      enough to cover anything the routers can do.
  #
  # Without this split, the old path — log → Matrix join → Discord
  # callback — easily blew past the 3s deadline for Approve/Decline, and
  # the user saw "This interaction failed".
  class InteractionHandler
    # Discord interaction types.
    INTERACTION_APPLICATION_COMMAND = 2
    INTERACTION_MESSAGE_COMPONENT   = 3

    # Callback/response types.
    ACK_DEFERRED_CHANNEL_MESSAGE = 5 # slash command ACK — "thinking…" pill
    ACK_DEFERRED_UPDATE_MESSAGE  = 6 # component ACK — no visible change

    # Ephemeral flag — locked in at ACK time for slash commands, can't be
    # added later via edit.
    EPHEMERAL_FLAG = 64

    # Long-lived single-purpose thread per interaction. A pool would
    # be safer under burst, but this bridge's interaction volume is
    # ~1/min and each thread lives <5s, so the simpler primitive wins.
    # rubocop:disable ThreadSafety/NewThread
    DEFAULT_SCHEDULER = ->(&block) { Thread.new(&block) }
    # rubocop:enable ThreadSafety/NewThread

    def initialize(
      client:,
      slash_command_router:,
      message_component_router:,
      journal: nil,
      scheduler: DEFAULT_SCHEDULER
    )
      @client = client
      @slash_command_router = slash_command_router
      @message_component_router = message_component_router
      @journal = journal
      @scheduler = scheduler
    end

    def call(payload)
      type = payload["type"]
      @journal&.info("Interaction received: #{label(payload)}", source: "gateway")

      ack = ack_payload_for(type)
      return unless ack

      @client.create_interaction_response(
        interaction_id: payload["id"],
        interaction_token: payload["token"],
        payload: ack,
      )

      @scheduler.call { run_deferred_work(payload, type) }
    rescue StandardError => e
      @journal&.warn(
        "Gateway interaction ACK failed: #{e.class}: #{e.message}",
        source: "gateway",
      )
    end

    private

    def ack_payload_for(type)
      case type
      when INTERACTION_APPLICATION_COMMAND
        { type: ACK_DEFERRED_CHANNEL_MESSAGE, data: { flags: EPHEMERAL_FLAG } }
      when INTERACTION_MESSAGE_COMPONENT
        { type: ACK_DEFERRED_UPDATE_MESSAGE }
      end
    end

    def run_deferred_work(payload, type)
      response = route(payload, type)
      return unless response

      # Routers return a full `{type:, data:}` envelope shaped for
      # create_interaction_response. For a deferred flow the envelope
      # is dropped — `data` IS the message body the edit endpoint expects.
      body = response[:data] || response["data"] || {}
      @client.edit_original_interaction_response(
        application_id: payload["application_id"],
        interaction_token: payload["token"],
        payload: body,
      )
      @journal&.info("Interaction answered: #{label(payload)}", source: "gateway")
    rescue Discord::NotFound
      # /endchat and /archive delete the channel the ephemeral "thinking…"
      # message lives in, so Discord 404s when we try to edit @original.
      # The command itself succeeded — don't alert #app-status. Discord's
      # raw "Unknown Message" text is omitted because it's opaque to
      # operators and the explanation here is the real signal.
      @journal&.info(
        "Interaction follow-up skipped for #{label(payload)} (ephemeral host channel was deleted by the command).",
        source: "gateway",
      )
    rescue StandardError => e
      @journal&.warn(
        "Gateway interaction callback failed: #{e.class}: #{e.message}",
        source: "gateway",
      )
    end

    def route(payload, type)
      case type
      when INTERACTION_APPLICATION_COMMAND
        @slash_command_router.dispatch(payload)
      when INTERACTION_MESSAGE_COMPONENT
        @message_component_router.dispatch(payload)
      end
    end

    def label(payload)
      case payload["type"]
      when INTERACTION_APPLICATION_COMMAND then "/#{payload.dig("data", "name")}"
      when INTERACTION_MESSAGE_COMPONENT then "button #{payload.dig("data", "custom_id")}"
      else "(type=#{payload["type"]})"
      end
    end
  end
end
