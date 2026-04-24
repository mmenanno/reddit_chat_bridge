# frozen_string_literal: true

require "faraday"
require "faraday/retry"

module Discord
  class Error < StandardError; end
  class AuthError < Error; end
  class NotFound < Error; end
  class BadRequest < Error; end
  class ServerError < Error; end

  class RateLimited < Error
    attr_reader :retry_after_ms

    def initialize(message, retry_after_ms:)
      super(message)
      @retry_after_ms = retry_after_ms
    end
  end

  # Minimal REST wrapper around the Discord bot API — the pieces the bridge
  # actually needs: create a text channel under a category, post a message,
  # fetch a channel (for reconcile). Narrow on purpose; the rest of the API
  # surface is someone else's problem.
  #
  # Uses `Authorization: Bot <token>` (not Bearer). Returns parsed JSON for
  # reads and the object's `id` for writes. Status-code handling translates
  # into typed errors the caller can rescue distinctly: auth failures alert
  # loudly, rate limits wait, 5xx retries, 404 triggers reconcile.
  class Client
    BASE_URL = "https://discord.com/api/v10/"
    CHANNEL_TYPE_TEXT = 0

    def initialize(bot_token:, base_url: BASE_URL, conn: nil)
      @bot_token = bot_token
      @base_url = base_url
      @conn = conn || build_connection
    end

    def create_channel(guild_id:, name:, parent_id: nil, topic: nil)
      payload = { name: name, type: CHANNEL_TYPE_TEXT }
      payload[:parent_id] = parent_id if parent_id
      payload[:topic] = topic if topic

      post("guilds/#{guild_id}/channels", payload: payload).body.fetch("id")
    end

    def send_message(channel_id:, content:)
      post("channels/#{channel_id}/messages", payload: { content: content }).body.fetch("id")
    end

    # Full-payload variant of send_message — exposes the REST endpoint
    # for callers that need embeds or message components (action rows,
    # buttons). Returns the full message body so callers can capture
    # the id for a later edit_message call.
    def create_message(channel_id:, payload:)
      post("channels/#{channel_id}/messages", payload: payload).body
    end

    def edit_message(channel_id:, message_id:, payload:)
      response = @conn.patch("channels/#{channel_id}/messages/#{message_id}") do |req|
        req.headers["Authorization"] = "Bot #{@bot_token}"
        req.body = payload
      end
      handle(response).body
    end

    def get_channel(channel_id)
      get("channels/#{channel_id}").body
    end

    # Bulk reorder request for channels in this guild. Each entry is
    # `{id:, position:}` — Discord applies the positions within the
    # channels' categories and handles the ripple on siblings. Other
    # channels not in the payload keep their existing positions.
    def reorder_channels(guild_id:, positions:)
      payload = positions.map { |pos| { id: pos.fetch(:id), position: pos.fetch(:position) } }
      response = @conn.patch("guilds/#{guild_id}/channels") do |req|
        req.headers["Authorization"] = "Bot #{@bot_token}"
        req.body = payload
      end
      handle(response)
      :ok
    end

    # Single PATCH that can carry any combination of name / topic / parent_id.
    # Discord accepts them together in one request so callers that need to
    # rename + retopicalize + move between categories don't burn extra
    # rate-limit slots.
    def update_channel(channel_id:, name: nil, topic: nil, parent_id: nil)
      body = {}
      body[:name] = name unless name.nil?
      body[:topic] = topic unless topic.nil?
      body[:parent_id] = parent_id unless parent_id.nil?
      return :ok if body.empty?

      response = @conn.patch("channels/#{channel_id}") do |req|
        req.headers["Authorization"] = "Bot #{@bot_token}"
        req.body = body
      end
      handle(response)
      :ok
    end

    def rename_channel(channel_id:, name:)
      update_channel(channel_id: channel_id, name: name)
    end

    def delete_channel(channel_id:)
      response = @conn.delete("channels/#{channel_id}") do |req|
        req.headers["Authorization"] = "Bot #{@bot_token}"
      end
      handle(response)
      :ok
    end

    def delete_message(channel_id:, message_id:)
      response = @conn.delete("channels/#{channel_id}/messages/#{message_id}") do |req|
        req.headers["Authorization"] = "Bot #{@bot_token}"
      end
      handle(response)
      :ok
    end

    # Bulk-replaces the guild's registered slash commands. One POST
    # with the full command list is the idempotent pattern Discord
    # documents — no need to compare/ diff on our side.
    def bulk_set_guild_commands(application_id:, guild_id:, commands:)
      path = "applications/#{application_id}/guilds/#{guild_id}/commands"
      response = @conn.put(path) do |req|
        req.headers["Authorization"] = "Bot #{@bot_token}"
        req.body = commands
      end
      handle(response).body
    end

    # Creates a channel webhook the bridge uses to post with per-message
    # username + avatar overrides. The returned token is a shared secret
    # scoped to that webhook — store it like a credential.
    def create_webhook(channel_id:, name:)
      post("channels/#{channel_id}/webhooks", payload: { name: name }).body
    end

    # Posts through a previously-created webhook. `?wait=true` asks Discord
    # to return the resulting message object so we can capture its id.
    # No bot-token header — the webhook token in the URL is the auth.
    def execute_webhook(webhook_id:, webhook_token:, payload:)
      path = "webhooks/#{webhook_id}/#{webhook_token}?wait=true"
      response = @conn.post(path) do |req|
        req.body = payload
      end
      handle(response).body.fetch("id")
    end

    # Completes a gateway-delivered interaction. Discord's public docs call
    # this the "create interaction response" endpoint. No bot-token header
    # (the interaction id + token pair is the authorization). Expected to
    # return 204 within 3s of the gateway dispatch.
    def create_interaction_response(interaction_id:, interaction_token:, payload:)
      path = "interactions/#{interaction_id}/#{interaction_token}/callback"
      response = @conn.post(path) do |req|
        req.body = payload
      end
      handle(response)
      :ok
    end

    # Follow-up endpoint paired with a deferred create_interaction_response
    # (types 5 or 6). Replaces the "thinking…" pill on a slash command, or
    # rewrites the component-bearing message after the handler's async work
    # finishes. Like execute_webhook, no bot-token header — the interaction
    # token in the URL is the auth, valid for 15 minutes from dispatch.
    def edit_original_interaction_response(application_id:, interaction_token:, payload:)
      path = "webhooks/#{application_id}/#{interaction_token}/messages/@original"
      response = @conn.patch(path) do |req|
        req.body = payload
      end
      handle(response)
      :ok
    end

    private

    def post(path, payload:)
      response = @conn.post(path) do |req|
        req.headers["Authorization"] = "Bot #{@bot_token}"
        req.body = payload
      end
      handle(response)
    end

    def get(path)
      response = @conn.get(path) do |req|
        req.headers["Authorization"] = "Bot #{@bot_token}"
      end
      handle(response)
    end

    def handle(response)
      case response.status
      when 200..299
        response
      when 400
        raise BadRequest, error_message(response)
      when 401, 403
        raise AuthError, error_message(response)
      when 404
        raise NotFound, error_message(response)
      when 429
        raise RateLimited.new(error_message(response), retry_after_ms: retry_after_ms(response))
      when 500..599
        raise ServerError, error_message(response)
      else
        raise Error, "HTTP #{response.status}: #{error_message(response)}"
      end
    end

    def error_message(response)
      body = response.body
      return body.to_s unless body.is_a?(Hash)

      base = body["message"] || body.to_s
      details = format_field_errors(body["errors"])
      details.empty? ? base : "#{base} (#{details})"
    end

    # Discord's 400 "Invalid Form Body" responses carry field-level detail in
    # a nested `errors` map — without flattening it into the exception
    # message, the log line just says "Invalid Form Body" with no hint which
    # field failed validation. Shape is e.g.
    #   { "topic" => { "_errors" => [{ "code" => "...", "message" => "..." }] } }
    # with arbitrary nesting for array-indexed fields like components.
    def format_field_errors(errors, path = [])
      return "" unless errors.is_a?(Hash)

      if errors["_errors"].is_a?(Array)
        return errors["_errors"].map do |err|
          label = path.join(".")
          detail = [err["code"], err["message"]].compact.reject(&:empty?).join(": ")
          "#{label}: #{detail}"
        end.join("; ")
      end

      errors.flat_map { |key, value| format_field_errors(value, path + [key]) }
        .reject(&:empty?).join("; ")
    end

    def retry_after_ms(response)
      seconds = response.body.is_a?(Hash) ? response.body["retry_after"] : nil
      return 0 unless seconds

      (seconds.to_f * 1000).to_i
    end

    def build_connection
      Faraday.new(url: @base_url) do |f|
        f.request(:json)
        f.response(:json, content_type: /\bjson$/)
        f.adapter(Faraday.default_adapter)
      end
    end
  end
end
