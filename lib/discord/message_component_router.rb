# frozen_string_literal: true

module Discord
  # Routes Discord MESSAGE_COMPONENT interactions (button clicks) by
  # their `custom_id`. Returns a Discord interaction-response Hash —
  # the caller (Bridge::Application) posts it back through
  # Discord::Client#create_interaction_response.
  #
  # Currently owns the `mr:<verb>:<id>` prefix used by
  # MessageRequestNotifier's Approve / Decline buttons. New button
  # families get another prefix + case branch; there's no framework
  # here intentionally — one file to grep, no indirection.
  class MessageComponentRouter
    # Interaction response types (Discord API v10).
    RESPONSE_UPDATE_MESSAGE = 7      # edits the message the button lives on
    RESPONSE_CHANNEL_MESSAGE = 4     # new message (ephemeral for errors)

    EPHEMERAL_FLAG = 64

    MESSAGE_REQUEST_ID_PATTERN = /\Amr:(approve|decline):(\d+)\z/

    def initialize(admin_actions:, notifier:)
      @admin_actions = admin_actions
      @notifier = notifier
    end

    def dispatch(payload)
      custom_id = payload.dig("data", "custom_id").to_s
      match = MESSAGE_REQUEST_ID_PATTERN.match(custom_id)
      return unknown_interaction unless match

      verb = match[1]
      id   = match[2].to_i
      handle_message_request(verb: verb, id: id)
    rescue StandardError => e
      ephemeral_error("#{e.class}: #{e.message}")
    end

    private

    def handle_message_request(verb:, id:)
      request = if verb == "approve"
        @admin_actions.approve_message_request!(id: id)
      else
        @admin_actions.decline_message_request!(id: id)
      end

      # UPDATE_MESSAGE: rewrites the original so the buttons are gone
      # and the embed shows the resolution. Matches the notifier's
      # resolution_payload shape exactly.
      { type: RESPONSE_UPDATE_MESSAGE, data: @notifier.resolution_payload(request) }
    end

    def unknown_interaction
      ephemeral_error("Unknown interaction — this button may be from an older deploy.")
    end

    def ephemeral_error(message)
      {
        type: RESPONSE_CHANNEL_MESSAGE,
        data: { content: "⚠️ #{message}", flags: EPHEMERAL_FLAG },
      }
    end
  end
end
