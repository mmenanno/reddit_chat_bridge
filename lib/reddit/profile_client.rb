# frozen_string_literal: true

require "cgi"
require "faraday"

module Reddit
  # Fetches a Reddit user's public profile avatar when Reddit's Matrix
  # backend didn't ship one on the chat member event. Hits the public
  # `/user/<name>/about.json` endpoint — unauthenticated, cacheable,
  # no OAuth required. Requires a non-default User-Agent; using a
  # descriptive one so Reddit's anti-abuse rate-limits us gracefully
  # instead of outright blocking.
  class ProfileClient
    BASE_URL = "https://www.reddit.com"
    USER_AGENT = "reddit_chat_bridge/1.0 (by /u/mmenanno)"

    def initialize(conn: nil, user_agent: USER_AGENT)
      @user_agent = user_agent
      @conn = conn || build_connection
    end

    # Returns an https URL or nil. Prefers snoovatar (the custom
    # illustrated avatar users build on reddit.com) over icon_img
    # (which for users without a custom avatar is a generic default
    # Snoo — same as Reddit chat shows, so falling back to it adds
    # no value).
    def fetch_avatar_url(username)
      return if username.to_s.strip.empty?

      response = @conn.get("/user/#{CGI.escape(username)}/about.json") do |req|
        req.headers["User-Agent"] = @user_agent
        req.headers["Accept"] = "application/json"
      end
      return unless response.status == 200

      data = response.body.is_a?(Hash) ? response.body["data"] : nil
      return unless data

      snoovatar = data["snoovatar_img"].to_s
      return strip_query(snoovatar) unless snoovatar.empty?

      icon = data["icon_img"].to_s
      # Skip the default Snoo — it's the same placeholder the chat shows
      # when the user has no avatar, so caching it is worse than nil
      # (Discord renders its own default, which is more distinct).
      return if icon.empty? || default_snoo?(icon)

      strip_query(icon)
    rescue Faraday::Error
      nil
    end

    private

    # Default avatars are hosted under styles.redditmedia.com/t5_* or
    # i.redd.it/static with `avatar_default_` in the path. Any other
    # icon_img is user-customised and worth surfacing.
    def default_snoo?(url)
      url.include?("avatar_default_")
    end

    # Reddit appends query params (?width=256&...) to cacheable assets;
    # stripping keeps storage + logs tidy and doesn't affect rendering.
    def strip_query(url)
      url.split("?").first
    end

    def build_connection
      Faraday.new(url: BASE_URL) do |f|
        f.response(:json, content_type: /\bjson$/)
        f.adapter(Faraday.default_adapter)
      end
    end
  end
end
