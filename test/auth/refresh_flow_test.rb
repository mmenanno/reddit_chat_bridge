# frozen_string_literal: true

require "test_helper"
require "auth/refresh_flow"

module Auth
  class RefreshFlowTest < ActiveSupport::TestCase
    CHAT_URL = "https://www.reddit.com/chat/"
    PAYLOAD_B64 = Base64.urlsafe_encode64('{"exp":1776540685.86127,"iat":1776454285}').tr("=", "")
    SAMPLE_JWT = "eyJhbGciOiJSUzI1NiJ9.#{PAYLOAD_B64}.sig".freeze
    COOKIE_JAR = "reddit_session=rs_jwt; token_v2=stale_matrix_jwt; loid=000000abc; edgebucket=e"

    def setup
      super
      @flow = Auth::RefreshFlow.new
    end

    test "refresh_now sends the cookie jar but strips token_v2 so Reddit re-mints" do
      stub_request(:get, CHAT_URL)
        .with(headers: { "Cookie" => "reddit_session=rs_jwt; loid=000000abc; edgebucket=e" })
        .to_return(status: 200, body: rs_app_html(SAMPLE_JWT, 1_776_540_685_000))

      @flow.refresh_now(cookie_jar: COOKIE_JAR)

      assert_requested(:get, CHAT_URL) do |req|
        refute_match(/token_v2=/, req.headers["Cookie"])
        assert_match(/reddit_session=rs_jwt/, req.headers["Cookie"])
      end
    end

    test "refresh_now returns the JWT extracted from <rs-app token=...>" do
      stub_request(:get, CHAT_URL)
        .to_return(status: 200, body: rs_app_html(SAMPLE_JWT, 1_776_540_685_000))

      result = @flow.refresh_now(cookie_jar: COOKIE_JAR)

      assert_equal(SAMPLE_JWT, result.access_token)
    end

    test "refresh_now returns the expires_at Time from the embedded JSON" do
      stub_request(:get, CHAT_URL)
        .to_return(status: 200, body: rs_app_html(SAMPLE_JWT, 1_776_540_685_000))

      result = @flow.refresh_now(cookie_jar: COOKIE_JAR)

      assert_equal(Time.at(1_776_540_685).utc, result.expires_at.utc)
    end

    test "refresh_now raises RefreshError on a non-200 response" do
      stub_request(:get, CHAT_URL).to_return(status: 403, body: "forbidden")

      error = assert_raises(Auth::RefreshFlow::RefreshError) do
        @flow.refresh_now(cookie_jar: COOKIE_JAR)
      end

      assert_match(/403/, error.message)
    end

    test "refresh_now raises RefreshError when the HTML doesn't contain an rs-app element" do
      stub_request(:get, CHAT_URL).to_return(status: 200, body: "<html><body>no rs-app here</body></html>")

      assert_raises(Auth::RefreshFlow::RefreshError) do
        @flow.refresh_now(cookie_jar: COOKIE_JAR)
      end
    end

    test "refresh_now raises RefreshError when the token attribute has malformed JSON" do
      html = '<html><body><rs-app token="&quot;not-json"></rs-app></body></html>'
      stub_request(:get, CHAT_URL).to_return(status: 200, body: html)

      assert_raises(Auth::RefreshFlow::RefreshError) do
        @flow.refresh_now(cookie_jar: COOKIE_JAR)
      end
    end

    test "refresh_now sends a desktop User-Agent so Reddit treats the request like a browser" do
      stub_request(:get, CHAT_URL)
        .to_return(status: 200, body: rs_app_html(SAMPLE_JWT, 1_776_540_685_000))

      @flow.refresh_now(cookie_jar: COOKIE_JAR)

      assert_requested(:get, CHAT_URL) do |req|
        assert_match(/Mozilla.*Macintosh|Linux|Windows/i, req.headers["User-Agent"])
      end
    end

    private

    def rs_app_html(jwt, expires_ms)
      blob = { token: jwt, expires: expires_ms }.to_json
      attr = CGI.escapeHTML(blob)
      %(<html><body><rs-app class="x" token="#{attr}" token-refresh-url="/svc/shreddit/token"></rs-app></body></html>)
    end
  end
end
