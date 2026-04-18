# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "bridge/web/app"

module Bridge
  module Web
    class AuthTest < ActiveSupport::TestCase
      include Rack::Test::Methods

      HOMESERVER = "https://matrix.redditspace.com"

      def app
        App
      end

      setup do
        AdminUser.create_with_password!(username: "michael", password: "hunter2hunter2")
        post("/login", username: "michael", password: "hunter2hunter2")
      end

      test "GET /auth renders the token page" do
        get "/auth"

        assert_equal(200, last_response.status)
        assert_match(/Matrix access token/, last_response.body)
      end

      test "GET /auth shows the empty state before reauth" do
        get "/auth"

        assert_match(/Not yet authenticated/, last_response.body)
      end

      test "GET /auth shows saved user and ok status after a successful probe" do
        AuthState.update_token!(access_token: "tok", user_id: "@t2_abc:reddit.com")

        get "/auth"

        assert_match(/@t2_abc:reddit\.com/, last_response.body)
      end

      test "POST /auth probes whoami and persists a good token" do
        stub_request(:get, "#{HOMESERVER}/_matrix/client/v3/account/whoami")
          .with(headers: { "Authorization" => "Bearer new_tok" })
          .to_return(
            status: 200,
            body: { user_id: "@t2_me:reddit.com" }.to_json,
            headers: { "Content-Type" => "application/json" },
          )

        post("/auth", access_token: "new_tok")

        assert_equal("new_tok", AuthState.access_token)
        assert_equal("@t2_me:reddit.com", AuthState.user_id)
      end

      test "POST /auth shows a success notice after saving a good token" do
        stub_request(:get, "#{HOMESERVER}/_matrix/client/v3/account/whoami")
          .to_return(
            status: 200,
            body: { user_id: "@t2_me:reddit.com" }.to_json,
            headers: { "Content-Type" => "application/json" },
          )

        post("/auth", access_token: "new_tok")

        assert_equal(200, last_response.status)
        assert_match(/Token probed and saved/, last_response.body)
      end

      test "POST /auth strips a 'Bearer ' prefix on paste" do
        stub_request(:get, "#{HOMESERVER}/_matrix/client/v3/account/whoami")
          .to_return(
            status: 200,
            body: { user_id: "@t2_me:reddit.com" }.to_json,
            headers: { "Content-Type" => "application/json" },
          )

        post("/auth", access_token: "  Bearer clean_tok  ")

        assert_equal("clean_tok", AuthState.access_token)
      end

      test "POST /auth rejects a token Reddit rejects without saving it" do
        AuthState.update_token!(access_token: "old_but_good", user_id: "@t2_old:reddit.com")
        stub_request(:get, "#{HOMESERVER}/_matrix/client/v3/account/whoami")
          .to_return(
            status: 401,
            body: { errcode: "M_UNKNOWN_TOKEN", error: "expired" }.to_json,
            headers: { "Content-Type" => "application/json" },
          )

        post("/auth", access_token: "bad_tok")

        assert_match(/Reddit rejected that token/, last_response.body)
        assert_equal("old_but_good", AuthState.access_token)
      end

      test "POST /auth with a blank token re-renders with an error" do
        post("/auth", access_token: "   ")

        assert_match(/Paste an access token/, last_response.body)
        assert_nil(AuthState.access_token)
      end

      test "POST /auth requires an authenticated session" do
        post("/logout")

        post("/auth", access_token: "leaked")

        assert_equal(302, last_response.status)
        assert_equal("/login", URI(last_response.location).path)
        assert_nil(AuthState.access_token)
      end
    end
  end
end
