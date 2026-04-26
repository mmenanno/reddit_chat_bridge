# frozen_string_literal: true

require "discord/colors"

module Discord
  # Posts a pending MessageRequest into Discord's #message-requests
  # channel as a rich embed with two buttons (Approve / Decline).
  # Button custom_ids follow the `mr:<verb>:<id>` shape so the
  # MessageComponentRouter can dispatch with a single regex match.
  #
  # Silently no-ops when no channel is configured — users with simpler
  # setups can rely on the /requests web page instead; we don't want a
  # dispatcher crash on an unconfigured optional channel.
  class MessageRequestNotifier
    BUTTON_STYLE_SUCCESS = 3
    BUTTON_STYLE_DANGER = 4
    COMPONENT_TYPE_ACTION_ROW = 1
    COMPONENT_TYPE_BUTTON = 2

    PREVIEW_MAX = 1000

    def initialize(client:, channel_id:, fallback_channel_id: nil)
      @client = client
      @channel_id = channel_id
      @fallback_channel_id = fallback_channel_id
    end

    def notify!(message_request)
      channel_id = resolved_channel_id
      return if channel_id.to_s.empty?

      result = @client.create_message(
        channel_id: channel_id,
        payload: pending_payload(message_request),
      )
      message_request.attach_discord_message!(
        channel_id: channel_id,
        message_id: result.fetch("id"),
      )
    end

    # Called after approve/decline — rewrites the original embed with a
    # status line and drops the action row so the buttons stop being
    # clickable. Returned payload is suitable for either a REST
    # edit_message call or an interaction response with type 7.
    def resolution_payload(message_request)
      {
        embeds: [resolved_embed(message_request)],
        components: [],
      }
    end

    # REST-path counterpart to resolution_payload — called from the web
    # UI's approve/decline routes so the orphaned Discord buttons stop
    # being clickable after a non-Discord resolution.
    def edit_resolution!(message_request)
      return unless message_request.discord_channel_id && message_request.discord_message_id

      @client.edit_message(
        channel_id: message_request.discord_channel_id,
        message_id: message_request.discord_message_id,
        payload: resolution_payload(message_request),
      )
    end

    def pending_payload(message_request)
      payload = {
        embeds: [pending_embed(message_request)],
        components: [action_row(message_request.id)],
      }
      avatar = message_request.inviter_avatar_url
      payload[:embeds].first[:thumbnail] = { url: avatar } if avatar.present?
      payload
    end

    private

    def resolved_channel_id
      return @channel_id if @channel_id && !@channel_id.empty?

      @fallback_channel_id
    end

    def pending_embed(request)
      {
        title: "📬 Message request from #{request.display_name}",
        description: description_for(request),
        color: Colors::EMBER,
        fields: pending_fields(request),
        footer: { text: "Pending · request ##{request.id}" },
      }.compact
    end

    def resolved_embed(request)
      color = request.approved? ? Colors::MOSS : Colors::RUST
      verb  = request.approved? ? "Approved" : "Declined"
      {
        title: "📬 Message request from #{request.display_name}",
        description: description_for(request),
        color: color,
        fields: [{ name: "Status", value: "#{verb} · #{request.resolved_at&.utc&.iso8601}", inline: false }],
        footer: { text: "Request ##{request.id}" },
      }.compact
    end

    def description_for(request)
      if request.preview_body.present?
        truncated = request.preview_body.to_s[0, PREVIEW_MAX]
        "#{quote(truncated)}\n\nApprove to join the Matrix room and start bridging; " \
          "decline to leave it (Reddit tells the sender their request was declined)."
      else
        "A new Reddit user wants to start a chat. Approve to join the Matrix room and " \
          "start bridging; decline to leave it (Reddit tells the sender their request was declined)."
      end
    end

    def pending_fields(request)
      fields = []
      fields << { name: "Reddit username", value: "u/#{request.inviter_username}", inline: true } if request.inviter_username.present?
      fields << { name: "Matrix ID", value: "`#{request.inviter_matrix_id}`", inline: true } if request.inviter_matrix_id.present?
      fields
    end

    def action_row(request_id)
      {
        type: COMPONENT_TYPE_ACTION_ROW,
        components: [
          {
            type: COMPONENT_TYPE_BUTTON,
            style: BUTTON_STYLE_SUCCESS,
            label: "Approve",
            custom_id: "mr:approve:#{request_id}",
            emoji: { name: "✅" },
          },
          {
            type: COMPONENT_TYPE_BUTTON,
            style: BUTTON_STYLE_DANGER,
            label: "Decline",
            custom_id: "mr:decline:#{request_id}",
            emoji: { name: "🚫" },
          },
        ],
      }
    end

    # Prefixes each line with Discord's blockquote marker so the preview
    # visually separates from our description copy — and so quoting it
    # inside the embed doesn't let Markdown in the sender's text accidentally
    # wrap our prose.
    def quote(text)
      text.each_line.map { |line| "> #{line.chomp}" }.join("\n")
    end
  end
end
