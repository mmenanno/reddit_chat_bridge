# frozen_string_literal: true

require "discord/slash_embed"

module Discord
  # Routes Discord MESSAGE_COMPONENT interactions (button clicks) by
  # their `custom_id`. Returns a Discord interaction-response Hash —
  # the caller (Bridge::Application) posts it back through
  # Discord::Client#create_interaction_response.
  #
  # Three button families today:
  #   - `mr:<verb>:<id>`           — Approve/Decline message requests
  #   - `unarchive:<verb>:<room>`  — Confirm/select/cancel for /unarchive
  #   - `restore:<verb>:<room>`    — Confirm/select/cancel for /restore
  #
  # New families add another regex + case branch; there's no framework
  # here intentionally — one file to grep, no indirection.
  class MessageComponentRouter
    # Interaction response types (Discord API v10).
    RESPONSE_UPDATE_MESSAGE = 7      # edits the message the button lives on
    RESPONSE_CHANNEL_MESSAGE = 4     # new message (ephemeral for errors)

    BUTTON_STYLE_SUCCESS   = 3
    BUTTON_STYLE_DANGER    = 4
    BUTTON_STYLE_SECONDARY = 2
    COMPONENT_TYPE_ACTION_ROW = 1
    COMPONENT_TYPE_BUTTON     = 2

    EPHEMERAL_FLAG = 64

    MESSAGE_REQUEST_PATTERN = /\Amr:(approve|decline):(\d+)\z/
    UNARCHIVE_PATTERN       = /\Aunarchive:(select|confirm|cancel):(\d+)\z/
    RESTORE_PATTERN         = /\Arestore:(select|confirm|cancel):(\d+)\z/

    def initialize(admin_actions:, notifier:)
      @admin_actions = admin_actions
      @notifier = notifier
    end

    def dispatch(payload)
      custom_id = payload.dig("data", "custom_id").to_s

      if (match = MESSAGE_REQUEST_PATTERN.match(custom_id))
        handle_message_request(verb: match[1], id: match[2].to_i)
      elsif (match = UNARCHIVE_PATTERN.match(custom_id))
        handle_room_action(verb: match[1], room_id: match[2].to_i, kind: :unarchive)
      elsif (match = RESTORE_PATTERN.match(custom_id))
        handle_room_action(verb: match[1], room_id: match[2].to_i, kind: :restore)
      else
        unknown_interaction
      end
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

    def handle_room_action(verb:, room_id:, kind:)
      case verb
      when "select"  then room_action_confirm(room_id: room_id, kind: kind)
      when "confirm" then room_action_apply(room_id: room_id, kind: kind)
      when "cancel"  then room_action_cancel(kind: kind)
      end
    end

    def room_action_confirm(room_id:, kind:)
      room = Room.find_by(id: room_id)
      return room_action_apply_missing(kind: kind) unless room

      label = action_label(kind)
      embed = SlashEmbed.info(
        title: "Confirm: #{label.downcase} #{room.counterparty_username || room.matrix_room_id}?",
        description: "Matrix room `#{room.matrix_room_id}` (room ##{room.id}).",
      )
      row = action_row([
        button(custom_id: "#{kind}:confirm:#{room.id}", style: BUTTON_STYLE_SUCCESS, label: "Yes, #{label.downcase}", emoji: "✅"),
        button(custom_id: "#{kind}:cancel:#{room.id}",  style: BUTTON_STYLE_SECONDARY, label: "Cancel"),
      ])
      update_payload(embed: embed, components: [row])
    end

    def room_action_apply(room_id:, kind:)
      room = Room.find_by(id: room_id)
      return room_action_apply_missing(kind: kind) unless room

      apply_action(room: room, kind: kind)
      label = action_label(kind)
      display = room.counterparty_username || room.matrix_room_id
      embed = SlashEmbed.success(
        title: "#{label}d #{display}",
        description: "Matrix room `#{room.matrix_room_id}` (room ##{room.id}) is back.",
      )
      update_payload(embed: embed, components: [])
    end

    def apply_action(room:, kind:)
      case kind
      when :unarchive then @admin_actions.unarchive_room!(matrix_room_id: room.matrix_room_id, backfill: true)
      when :restore   then @admin_actions.restore_chat!(matrix_room_id: room.matrix_room_id)
      end
    end

    def room_action_cancel(kind:)
      label = action_label(kind)
      embed = SlashEmbed.warn(
        title: "#{label} cancelled",
        description: "No changes were made.",
      )
      update_payload(embed: embed, components: [])
    end

    def room_action_apply_missing(kind:)
      embed = SlashEmbed.error(message: "Room is gone - #{kind} cannot continue. Re-run the slash command.")
      update_payload(embed: embed, components: [])
    end

    def action_label(kind)
      case kind
      when :unarchive then "Unarchive"
      when :restore   then "Restore"
      end
    end

    def update_payload(embed:, components:)
      { type: RESPONSE_UPDATE_MESSAGE, data: { embeds: [embed], components: components } }
    end

    def action_row(buttons)
      { type: COMPONENT_TYPE_ACTION_ROW, components: buttons }
    end

    def button(custom_id:, style:, label:, emoji: nil)
      btn = { type: COMPONENT_TYPE_BUTTON, style: style, custom_id: custom_id, label: label }
      btn[:emoji] = { name: emoji } if emoji
      btn
    end

    def unknown_interaction
      ephemeral_error("Unknown interaction - this button may be from an older deploy.")
    end

    def ephemeral_error(message)
      {
        type: RESPONSE_CHANNEL_MESSAGE,
        data: { content: "⚠️ #{message}", flags: EPHEMERAL_FLAG },
      }
    end
  end
end
