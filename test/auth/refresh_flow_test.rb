# frozen_string_literal: true

require "test_helper"
require "auth/refresh_flow"

module Auth
  class RefreshFlowTest < ActiveSupport::TestCase
    CHAT_URL = "https://www.reddit.com/chat/"
    MATRIX_LOGIN_URL = "https://matrix.redditspace.com/_matrix/client/v3/login"
    PAYLOAD_B64 = Base64.urlsafe_encode64('{"exp":1776540685.86127,"iat":1776454285}').tr("=", "")
    SAMPLE_JWT = "eyJhbGciOiJSUzI1NiJ9.#{PAYLOAD_B64}.sig".freeze
    COOKIE_JAR = "reddit_session=rs_jwt; token_v2=stale_matrix_jwt; loid=000000abc; edgebucket=e"

    setup do
      @flow = Auth::RefreshFlow.new
      # Default: both endpoints respond successfully. Individual tests
      # override specific stubs.
      stub_request(:get, CHAT_URL).to_return(status: 200, body: rs_app_html(SAMPLE_JWT, 1_776_540_685_000))
      stub_request(:post, MATRIX_LOGIN_URL).to_return(status: 200, body: { access_token: SAMPLE_JWT }.to_json)
    end

    test "refresh_now sends the cookie jar but strips token_v2 so Reddit re-mints" do
      @flow.refresh_now(cookie_jar: COOKIE_JAR)

      assert_requested(:get, CHAT_URL) do |req|
        refute_match(/token_v2=/, req.headers["Cookie"])
        assert_match(/reddit_session=rs_jwt/, req.headers["Cookie"])
      end
    end

    test "refresh_now POSTs to Matrix /login with com.reddit.token type and the minted JWT" do
      @flow.refresh_now(cookie_jar: COOKIE_JAR)

      assert_requested(:post, MATRIX_LOGIN_URL) do |req|
        body = JSON.parse(req.body)
        body["type"] == "com.reddit.token" && body["token"] == SAMPLE_JWT
      end
    end

    test "refresh_now's Matrix /login request identifies the client as 'reddit_chat_bridge'" do
      @flow.refresh_now(cookie_jar: COOKIE_JAR)

      assert_requested(:post, MATRIX_LOGIN_URL) do |req|
        JSON.parse(req.body)["initial_device_display_name"] == "reddit_chat_bridge"
      end
    end

    test "refresh_now returns the minted JWT as access_token" do
      result = @flow.refresh_now(cookie_jar: COOKIE_JAR)

      assert_equal(SAMPLE_JWT, result.access_token)
    end

    test "refresh_now returns the expires_at Time from the embedded JSON" do
      result = @flow.refresh_now(cookie_jar: COOKIE_JAR)

      assert_equal(Time.at(1_776_540_685).utc, result.expires_at.utc)
    end

    test "refresh_now raises RefreshError on a non-200 /chat/ response" do
      stub_request(:get, CHAT_URL).to_return(status: 403, body: "forbidden")

      error = assert_raises(Auth::RefreshFlow::RefreshError) do
        @flow.refresh_now(cookie_jar: COOKIE_JAR)
      end

      assert_match(/403/, error.message)
    end

    test "refresh_now raises RefreshError when /chat/ HTML has no rs-app element" do
      stub_request(:get, CHAT_URL).to_return(status: 200, body: "<html><body>no rs-app</body></html>")

      assert_raises(Auth::RefreshFlow::RefreshError) do
        @flow.refresh_now(cookie_jar: COOKIE_JAR)
      end
    end

    test "refresh_now raises RefreshError when Matrix /login rejects the minted JWT" do
      stub_request(:post, MATRIX_LOGIN_URL)
        .to_return(status: 401, body: { errcode: "M_UNKNOWN_TOKEN", error: "bad" }.to_json)

      error = assert_raises(Auth::RefreshFlow::RefreshError) do
        @flow.refresh_now(cookie_jar: COOKIE_JAR)
      end

      assert_match(%r{Matrix /login rejected}, error.message)
    end

    private

    def rs_app_html(jwt, expires_ms)
      blob = { token: jwt, expires: expires_ms }.to_json
      attr = CGI.escapeHTML(blob)
      %(<html><body><rs-app class="x" token="#{attr}" token-refresh-url="/svc/shreddit/token"></rs-app></body></html>)
    end
  end
end
