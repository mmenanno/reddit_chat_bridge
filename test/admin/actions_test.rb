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

    # ---- full_resync! ----

    test "full_resync! clears discord_channel_id and last_event_id on every room" do
      Room.create!(matrix_room_id: "!a:reddit.com", discord_channel_id: "111", last_event_id: "$one")
      Room.create!(matrix_room_id: "!b:reddit.com", discord_channel_id: "222", last_event_id: "$two")

      @actions.full_resync!

      Room.find_each do |room|
        assert_nil(room.discord_channel_id)
        assert_nil(room.last_event_id)
      end
    end

    test "full_resync! deletes every PostedEvent row" do
      PostedEvent.record!(event_id: "$a", room_id: "!a:reddit.com")
      PostedEvent.record!(event_id: "$b", room_id: "!b:reddit.com")

      @actions.full_resync!

      assert_equal(0, PostedEvent.count)
    end

    test "full_resync! clears the sync checkpoint" do
      SyncCheckpoint.advance!("some_token")

      @actions.full_resync!

      assert_nil(SyncCheckpoint.next_batch_token)
    end

    test "full_resync! preserves Room rows and counterparty usernames" do
      Room.create!(
        matrix_room_id: "!a:reddit.com",
        counterparty_matrix_id: "@t2_peer:reddit.com",
        counterparty_username: "nothnnn",
        discord_channel_id: "111",
      )

      @actions.full_resync!

      assert_equal(1, Room.count)
      assert_equal("nothnnn", Room.first.counterparty_username)
    end

    test "full_resync! returns counts of what it cleared and (with no reconciler) zero rebuilds" do
      Room.create!(matrix_room_id: "!a:reddit.com", discord_channel_id: "111")
      Room.create!(matrix_room_id: "!b:reddit.com", discord_channel_id: "222")
      PostedEvent.record!(event_id: "$a", room_id: "!a:reddit.com")

      stats = @actions.full_resync!

      assert_equal(
        { rooms_reset: 2, events_cleared: 1, rebuilt: 0, rebuild_errors: 0 },
        stats,
      )
    end

    test "full_resync! rebuilds every room when a reconciler is wired" do
      Room.create!(matrix_room_id: "!a:reddit.com", discord_channel_id: "111")
      Room.create!(matrix_room_id: "!b:reddit.com", discord_channel_id: "222")

      reconciler = mock("Reconciler")
      reconciler.expects(:refresh_one).with(matrix_room_id: "!a:reddit.com").returns(renamed: true, posted_attempted: 3)
      reconciler.expects(:refresh_one).with(matrix_room_id: "!b:reddit.com").returns(renamed: true, posted_attempted: 5)

      actions = Admin::Actions.new(
        matrix_client_factory: ->(_) { @probe_client },
        refresh_flow: @refresh_flow,
        reconciler: reconciler,
      )

      stats = actions.full_resync!

      assert_equal(2, stats[:rebuilt])
      assert_equal(0, stats[:rebuild_errors])
    end

    # ---- rebuild_all! (non-destructive) ----

    test "rebuild_all! requires a reconciler" do
      assert_raises(Admin::Actions::NotConfiguredError) { @actions.rebuild_all! }
    end

    test "rebuild_all! runs refresh_one on every room and returns counts" do
      Room.create!(matrix_room_id: "!a:reddit.com")
      Room.create!(matrix_room_id: "!b:reddit.com")

      reconciler = mock("Reconciler")
      reconciler.expects(:refresh_one).with(matrix_room_id: "!a:reddit.com").returns(renamed: true, posted_attempted: 2)
      reconciler.expects(:refresh_one).with(matrix_room_id: "!b:reddit.com").returns(renamed: true, posted_attempted: 0)

      actions = Admin::Actions.new(
        matrix_client_factory: ->(_) { @probe_client },
        refresh_flow: @refresh_flow,
        reconciler: reconciler,
      )

      assert_equal({ rebuilt: 2, rebuild_errors: 0 }, actions.rebuild_all!)
    end

    test "full_resync! counts rebuild failures without aborting the loop" do
      Room.create!(matrix_room_id: "!a:reddit.com", discord_channel_id: "111")
      Room.create!(matrix_room_id: "!b:reddit.com", discord_channel_id: "222")

      reconciler = mock("Reconciler")
      reconciler.expects(:refresh_one).with(matrix_room_id: "!a:reddit.com").raises(RuntimeError, "boom")
      reconciler.expects(:refresh_one).with(matrix_room_id: "!b:reddit.com").returns(renamed: true, posted_attempted: 0)

      actions = Admin::Actions.new(
        matrix_client_factory: ->(_) { @probe_client },
        refresh_flow: @refresh_flow,
        reconciler: reconciler,
      )

      stats = actions.full_resync!

      assert_equal(1, stats[:rebuilt])
      assert_equal(1, stats[:rebuild_errors])
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

    # ---- reconcile_channels! / refresh_room! ----

    test "reconcile_channels! delegates to the injected reconciler" do
      reconciler = mock("Reconciler")
      reconciler.expects(:reconcile_all).returns(renamed: 3, skipped: 1, errors: 0)
      actions = Admin::Actions.new(
        matrix_client_factory: ->(_) { @probe_client },
        refresh_flow: @refresh_flow,
        reconciler: reconciler,
      )

      assert_equal({ renamed: 3, skipped: 1, errors: 0 }, actions.reconcile_channels!)
    end

    test "refresh_room! delegates to the injected reconciler" do
      reconciler = mock("Reconciler")
      reconciler.expects(:refresh_one).with(matrix_room_id: "!r:reddit.com").returns(renamed: true, posted_attempted: 5)
      actions = Admin::Actions.new(
        matrix_client_factory: ->(_) { @probe_client },
        refresh_flow: @refresh_flow,
        reconciler: reconciler,
      )

      assert_equal({ renamed: true, posted_attempted: 5 }, actions.refresh_room!(matrix_room_id: "!r:reddit.com"))
    end

    test "reconcile_channels! raises NotConfiguredError without a reconciler" do
      assert_raises(Admin::Actions::NotConfiguredError) { @actions.reconcile_channels! }
    end

    test "refresh_room! raises NotConfiguredError without a reconciler" do
      assert_raises(Admin::Actions::NotConfiguredError) do
        @actions.refresh_room!(matrix_room_id: "!r:reddit.com")
      end
    end
  end
end
