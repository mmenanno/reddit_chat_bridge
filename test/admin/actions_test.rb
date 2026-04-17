# frozen_string_literal: true

require "test_helper"
require "matrix/client"
require "admin/actions"

module Admin
  class ActionsTest < ActiveSupport::TestCase
    NEW_TOKEN = "fresh_token_value"
    NEW_USER = "@t2_self:reddit.com"
    SESSION_PAYLOAD_B64 = Base64.urlsafe_encode64('{"exp":1791775617}').tr("=", "")
    COOKIE_JAR = "reddit_session=eyJhbGciOiJSUzI1NiJ9.#{SESSION_PAYLOAD_B64}.sig; loid=000000abc; token_v2=stale".freeze

    def setup
      super
      # AuthState's cookie encryption needs a session_secret.
      AppConfig.set("session_secret", "test_secret_for_encryption_at_rest")

      @built_with = []
      @probe_client = Matrix::Client.new(access_token: NEW_TOKEN)
      factory = lambda { |token|
        @built_with << token
        @probe_client
      }

      @refresh_flow = mock("RefreshFlow")
      @actions = Admin::Actions.new(
        matrix_client_factory: factory,
        refresh_flow: @refresh_flow,
      )
    end

    # ---- reauth ----

    test "reauth probes the new token via whoami before saving" do
      @probe_client.expects(:whoami).returns("user_id" => NEW_USER)

      @actions.reauth(access_token: NEW_TOKEN)

      assert_equal([NEW_TOKEN], @built_with)
    end

    test "reauth persists the token and user_id on probe success" do
      @probe_client.stubs(:whoami).returns("user_id" => NEW_USER)

      @actions.reauth(access_token: NEW_TOKEN)

      assert_equal(NEW_TOKEN, AuthState.access_token)
      assert_equal(NEW_USER, AuthState.user_id)
    end

    test "reauth marks auth state healthy on success" do
      AuthState.mark_failure!("earlier failure")
      @probe_client.stubs(:whoami).returns("user_id" => NEW_USER)

      @actions.reauth(access_token: NEW_TOKEN)

      refute_predicate(AuthState, :paused?)
    end

    test "reauth returns :ok on success" do
      @probe_client.stubs(:whoami).returns("user_id" => NEW_USER)

      assert_equal(:ok, @actions.reauth(access_token: NEW_TOKEN))
    end

    test "reauth propagates Matrix::TokenError without saving the bad token" do
      @probe_client.stubs(:whoami).raises(Matrix::TokenError, "M_UNKNOWN_TOKEN")
      AuthState.update_token!(access_token: "existing", user_id: "@t2_old:reddit.com")

      assert_raises(Matrix::TokenError) do
        @actions.reauth(access_token: NEW_TOKEN)
      end

      assert_equal("existing", AuthState.access_token)
    end

    # ---- resync ----

    test "resync clears the next_batch token" do
      SyncCheckpoint.advance!("some_batch")

      @actions.resync

      assert_nil(SyncCheckpoint.next_batch_token)
    end

    test "resync returns :ok" do
      assert_equal(:ok, @actions.resync)
    end

    # ---- set_reddit_cookies! ----

    test "set_reddit_cookies! mints a fresh token via RefreshFlow and saves everything" do
      result = Auth::RefreshFlow::Result.new(access_token: NEW_TOKEN, expires_at: Time.at(1_776_540_685).utc)
      @refresh_flow.expects(:refresh_now).with(cookie_jar: COOKIE_JAR).returns(result)
      @probe_client.stubs(:whoami).returns("user_id" => NEW_USER)

      @actions.set_reddit_cookies!(COOKIE_JAR)

      assert_equal(NEW_TOKEN, AuthState.access_token)
      assert_equal(NEW_USER, AuthState.user_id)
      assert_equal(COOKIE_JAR, AuthState.reddit_cookie_jar)
    end

    test "set_reddit_cookies! raises when the cookie jar is empty" do
      assert_raises(ArgumentError) { @actions.set_reddit_cookies!("   ") }
    end

    test "set_reddit_cookies! propagates RefreshError without touching AuthState" do
      AuthState.update_token!(access_token: "existing", user_id: "@t2_old:reddit.com")
      @refresh_flow.stubs(:refresh_now).raises(Auth::RefreshFlow::RefreshError, "GET /chat/ returned 403")

      assert_raises(Auth::RefreshFlow::RefreshError) { @actions.set_reddit_cookies!(COOKIE_JAR) }

      assert_equal("existing", AuthState.access_token)
      assert_nil(AuthState.reddit_cookie_jar)
    end

    # ---- refresh_matrix_token! ----

    test "refresh_matrix_token! uses the stored cookie jar to mint a fresh token" do
      AuthState.store_reddit_session!(COOKIE_JAR)
      AuthState.update_token!(access_token: "old", user_id: NEW_USER)
      result = Auth::RefreshFlow::Result.new(access_token: NEW_TOKEN, expires_at: Time.at(1_776_540_685).utc)
      @refresh_flow.expects(:refresh_now).with(cookie_jar: COOKIE_JAR).returns(result)

      @actions.refresh_matrix_token!

      assert_equal(NEW_TOKEN, AuthState.access_token)
      assert_equal(NEW_USER, AuthState.user_id)
    end

    test "refresh_matrix_token! raises when no cookies are stored yet" do
      assert_raises(Auth::RefreshFlow::RefreshError) { @actions.refresh_matrix_token! }
    end
  end
end
