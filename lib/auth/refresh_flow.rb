# frozen_string_literal: true

require "cgi"
require "faraday"
require "json"

module Auth
  # Refreshes the Matrix access token by having Reddit's backend re-mint it.
  #
  # Reddit's chat.reddit.com bootstrap returns an SSR'd HTML page with a
  # custom `<rs-app token="{json}">` element containing the current Matrix
  # JWT. Omitting the `token_v2` cookie forces the backend to mint a fresh
  # JWT on demand — the spike in `bin/spike_token_refresh` proved this.
  #
  # Everything else — reddit_session, loid, session_tracker, edgebucket —
  # stays in the cookie jar so Reddit authenticates the request as the
  # logged-in user.
  class RefreshFlow
    CHAT_URL = "https://www.reddit.com/chat/"
    DEFAULT_USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " \
                         "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3.1 Safari/605.1.15"

    RS_APP_TOKEN_PATTERN = /<rs-app[^>]*\stoken="([^"]*)"/m

    class RefreshError < StandardError; end

    Result = Data.define(:access_token, :expires_at)

    def initialize(conn: nil, user_agent: DEFAULT_USER_AGENT)
      @conn = conn || build_connection
      @user_agent = user_agent
    end

    def refresh_now(cookie_jar:)
      stripped = strip_token_v2(cookie_jar)
      response = @conn.get("/chat/") do |req|
        req.headers["Cookie"] = stripped
        req.headers["User-Agent"] = @user_agent
        req.headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9"
      end

      raise RefreshError, "GET /chat/ returned status #{response.status}" unless response.status == 200

      parsed = extract_token_blob(response.body)
      raise RefreshError, "no <rs-app token=...> in /chat/ response" unless parsed
      raise RefreshError, "rs-app token attribute missing 'token' key" unless parsed["token"]

      Result.new(
        access_token: parsed["token"],
        expires_at: parsed["expires"] ? Time.at(parsed["expires"].to_f / 1000).utc : nil,
      )
    end

    private

    def strip_token_v2(cookie_jar)
      cookie_jar.to_s
        .split(/;\s*/)
        .reject { |pair| pair.start_with?("token_v2=") }
        .join("; ")
    end

    def extract_token_blob(html)
      match = html.match(RS_APP_TOKEN_PATTERN)
      return unless match

      decoded = CGI.unescapeHTML(match[1])
      JSON.parse(decoded)
    rescue JSON::ParserError => e
      raise RefreshError, "rs-app token attribute has malformed JSON: #{e.message}"
    end

    def build_connection
      Faraday.new(url: "https://www.reddit.com") do |f|
        f.adapter(Faraday.default_adapter)
      end
    end
  end
end
