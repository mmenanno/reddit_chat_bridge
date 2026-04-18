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

    def create_channel(guild_id:, name:, parent_id: nil)
      payload = { name: name, type: CHANNEL_TYPE_TEXT }
      payload[:parent_id] = parent_id if parent_id

      post("guilds/#{guild_id}/channels", payload: payload).body.fetch("id")
    end

    def send_message(channel_id:, content:)
      post("channels/#{channel_id}/messages", payload: { content: content }).body.fetch("id")
    end

    def get_channel(channel_id)
      get("channels/#{channel_id}").body
    end

    def rename_channel(channel_id:, name:)
      response = @conn.patch("channels/#{channel_id}") do |req|
        req.headers["Authorization"] = "Bot #{@bot_token}"
        req.body = { name: name }
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

      body["message"] || body.to_s
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
