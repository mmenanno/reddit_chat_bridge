# frozen_string_literal: true

require "cgi"
require "faraday"
require "faraday/retry"

module Matrix
  class Error < StandardError; end
  class TokenError < Error; end
  class ServerError < Error; end

  # Thin Faraday-backed wrapper around the Reddit Matrix Client-Server API.
  #
  # Deliberately narrow: `whoami`, `sync`, and `send_message` — the exact
  # endpoints the bridge needs. No attempt to model the whole protocol.
  #
  # The connection is injectable so tests can drop in a Faraday adapter stub
  # and production can share a connection across threads if we need to
  # later. By default each instance builds its own connection.
  class Client
    DEFAULT_HOMESERVER = "https://matrix.redditspace.com"
    DEFAULT_TIMEOUT_MS = 10_000

    def initialize(access_token:, homeserver: DEFAULT_HOMESERVER, conn: nil)
      # access_token may be a static String or a callable that returns one.
      # The callable form lets production threads pick up a reauth'd token
      # from AuthState without recreating the client; tests pass the String.
      @access_token_source = access_token
      @homeserver = homeserver
      @conn = conn || build_connection
    end

    def whoami
      get("/_matrix/client/v3/account/whoami").body
    end

    def sync(since: nil, timeout_ms: DEFAULT_TIMEOUT_MS)
      params = { "timeout" => timeout_ms.to_s }
      params["since"] = since if since

      get("/_matrix/client/v3/sync", params: params).body
    end

    def send_message(room_id:, body:, txn_id:)
      path = "/_matrix/client/v3/rooms/#{CGI.escape(room_id)}/send/m.room.message/#{CGI.escape(txn_id)}"
      response = put(path, payload: { msgtype: "m.text", body: body })
      response.body.fetch("event_id")
    end

    # Pulls recent timeline events for a single room, used by the per-room
    # force-refresh action to re-examine history without replaying /sync.
    # `dir` is "b" (backward from the latest event) or "f" (forward from
    # `from`). Returns the raw body: `{ "chunk" => [...], "state" => [...],
    # "start" => "...", "end" => "..." }`.
    def room_messages(room_id:, dir: "b", limit: 50, from: nil)
      path = "/_matrix/client/v3/rooms/#{CGI.escape(room_id)}/messages"
      params = { "dir" => dir, "limit" => limit.to_s }
      params["from"] = from if from
      get(path, params: params).body
    end

    # Returns { "displayname" => "...", "avatar_url" => "..." } or nil if the
    # profile isn't exposed. Used when /sync's lazy-load state didn't include
    # m.room.member for this user (can happen on resume syncs) — we still
    # want a human-readable channel name.
    def profile(user_id:)
      path = "/_matrix/client/v3/profile/#{CGI.escape(user_id)}"
      get(path).body
    rescue TokenError
      raise
    rescue Error
      # A missing profile shouldn't break the whole sync loop; return nil and
      # let the caller fall back to the matrix_id slug.
      nil
    end

    private

    def current_token
      @access_token_source.respond_to?(:call) ? @access_token_source.call : @access_token_source
    end

    def get(path, params: nil)
      response = @conn.get(path) do |req|
        req.headers["Authorization"] = "Bearer #{current_token}"
        params&.each_pair { |key, value| req.params[key] = value }
      end
      handle(response)
    end

    def put(path, payload:)
      response = @conn.put(path) do |req|
        req.headers["Authorization"] = "Bearer #{current_token}"
        req.body = payload
      end
      handle(response)
    end

    def handle(response)
      return response if response.status == 200
      raise TokenError, error_message(response) if response.status == 401
      raise ServerError, error_message(response) if (500..599).cover?(response.status)

      raise Error, "HTTP #{response.status}: #{error_message(response)}"
    end

    def error_message(response)
      body = response.body
      return body.to_s unless body.is_a?(Hash)

      [body["errcode"], body["error"]].compact.join(": ")
    end

    def build_connection
      Faraday.new(url: @homeserver) do |f|
        f.request(:json)
        f.response(:json, content_type: /\bjson$/)
        f.adapter(Faraday.default_adapter)
      end
    end
  end
end
