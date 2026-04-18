# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "bridge/web/app"

module Bridge
  module Web
    class RoomsAndActionsTest < ActiveSupport::TestCase
      include Rack::Test::Methods

      def app
        App
      end

      setup do
        AdminUser.create_with_password!(username: "michael", password: "hunter2hunter2")
        post("/login", username: "michael", password: "hunter2hunter2")
      end

      # ---- /rooms ----

      test "GET /rooms with no bridged rooms shows an empty-state message" do
        get "/rooms"

        assert_equal(200, last_response.status)
        assert_match(/Nothing bridged yet/, last_response.body)
      end

      test "GET /rooms renders a row for each known room" do
        Room.create!(
          matrix_room_id: "!one:reddit.com",
          counterparty_username: "nothnnn",
          discord_channel_id: "123",
        )
        Room.create!(
          matrix_room_id: "!two:reddit.com",
          counterparty_username: "testuser",
        )

        get "/rooms"

        assert_match(/nothnnn/, last_response.body)
        assert_match(/testuser/, last_response.body)
        assert_match(/!one:reddit\.com/, last_response.body)
      end

      test "GET /rooms shows the preserved username + deleted marker for rooms flagged as deleted" do
        Room.create!(
          matrix_room_id: "!one:reddit.com",
          counterparty_matrix_id: "@t2_goner:reddit.com",
          counterparty_username: "Relative-Bee-4118",
          counterparty_deleted_at: Time.current,
        )

        get "/rooms"

        assert_match(/Relative-Bee-4118/, last_response.body)
        assert_match(/deleted-marker/, last_response.body)
      end

      test "GET /rooms falls back to the matrix_id localpart when a deleted room has no preserved username" do
        Room.create!(
          matrix_room_id: "!one:reddit.com",
          counterparty_matrix_id: "@t2_24t6x7wqhl:reddit.com",
          counterparty_deleted_at: Time.current,
        )

        get "/rooms"

        # Legacy rows where the buggy "[deleted]" overwrite wiped the real
        # name — the UI now shows the Reddit localpart (t2_24t6x7wqhl)
        # instead of a bare "unresolved" placeholder.
        assert_match(/t2_24t6x7wqhl/, last_response.body)
        assert_match(/deleted-marker/, last_response.body)
      end

      test "GET /rooms marks rooms without a discord channel as 'not created'" do
        Room.create!(
          matrix_room_id: "!one:reddit.com",
          counterparty_username: "nothnnn",
        )

        get "/rooms"

        assert_match(/not created/, last_response.body)
      end

      test "GET /rooms redirects unauthenticated users to /login" do
        post "/logout"

        get "/rooms"

        assert_equal(302, last_response.status)
        assert_equal("/login", URI(last_response.location).path)
      end

      # ---- GET /rooms/:id transcript ----

      test "GET /rooms/:id returns a themed 404 page when the room is unknown" do
        get "/rooms/9999"

        # The themed 404 view carries the "Stray thread" kicker and echoes
        # the bad id back — confirms we're rendering :not_found, not Sinatra's
        # plain-text fallback, and that the /rooms/:id-specific reason wins
        # over the generic one.
        assert_equal(404, last_response.status)
        assert_match(%r{§404 / Stray thread.*id "9999"}m, last_response.body)
      end

      test "unknown routes render the themed 404 page instead of Sinatra's plaintext" do
        get "/not-a-real-path"

        assert_equal(404, last_response.status)
        assert_match(%r{§404 / Stray thread.*/not-a-real-path}m, last_response.body)
      end

      test "unhandled exceptions render the themed 500 page instead of Puma's plaintext" do
        # Tests default to raise_errors=true (tests want real exceptions
        # surfaced by rack-test). Flip it off for this one test so the
        # `error do` handler actually runs, then restore.
        App.set(:raise_errors, false)
        Room.stubs(:order).raises(StandardError, "synthetic boom")

        get("/rooms")

        assert_equal(500, last_response.status)
        assert_match(%r{§500 / Snapped wire.*synthetic boom}m, last_response.body)
      ensure
        App.set(:raise_errors, true)
      end

      test "GET /rooms/:id shows the auth-paused banner without hitting Matrix when the token is missing" do
        room = Room.create!(
          matrix_room_id: "!abc:reddit.com",
          counterparty_username: "testuser",
        )
        AuthState.current.update!(access_token: nil, user_id: "@t2_self:reddit.com")

        get "/rooms/#{room.id}"

        assert_match(/Matrix auth is paused or missing/, last_response.body)
        assert_not_requested(:any, /matrix\.redditspace\.com/)
      end

      test "GET /rooms/:id renders transcript messages in chronological order" do
        room = Room.create!(
          matrix_room_id: "!abc:reddit.com",
          counterparty_username: "testuser",
          counterparty_matrix_id: "@t2_peer:reddit.com",
        )
        seed_matrix_auth
        stub_matrix_messages(
          room_id: "!abc:reddit.com",
          chunk: [
            {
              "type" => "m.room.message",
              "event_id" => "$new",
              "sender" => "@t2_peer:reddit.com",
              "origin_server_ts" => 1_776_400_000_000,
              "content" => { "msgtype" => "m.text", "body" => "latest ping" },
            },
            {
              "type" => "m.room.message",
              "event_id" => "$older",
              "sender" => "@t2_peer:reddit.com",
              "origin_server_ts" => 1_776_399_000_000,
              "content" => { "msgtype" => "m.text", "body" => "earlier note" },
            },
          ],
          end_token: "t_older",
        )

        get "/rooms/#{room.id}"

        # Oldest first: chunk came back newest-first from Matrix; view reverses
        # it so humans read the older message above the newer one.
        assert_match(/earlier note.*latest ping/m, last_response.body)
      end

      test "GET /rooms/:id surfaces the pagination end_token in a Load older link" do
        room = Room.create!(matrix_room_id: "!abc:reddit.com", counterparty_username: "testuser")
        seed_matrix_auth
        stub_matrix_messages(
          room_id: "!abc:reddit.com",
          chunk: [{
            "type" => "m.room.message",
            "event_id" => "$one",
            "sender" => "@t2_peer:reddit.com",
            "origin_server_ts" => 1_776_400_000_000,
            "content" => { "msgtype" => "m.text", "body" => "only" },
          }],
          end_token: "t_older",
        )

        get "/rooms/#{room.id}"

        assert_match(/from=t_older/, last_response.body)
      end

      test "GET /rooms/:id renders an empty state when the chunk comes back empty" do
        room = Room.create!(
          matrix_room_id: "!abc:reddit.com",
          counterparty_username: "testuser",
        )
        seed_matrix_auth
        stub_matrix_messages(room_id: "!abc:reddit.com", chunk: [], end_token: nil)

        get "/rooms/#{room.id}"

        assert_equal(200, last_response.status)
        assert_match(/No messages yet/, last_response.body)
      end

      test "GET /rooms/:id forwards ?from pagination cursor to the Matrix call" do
        room = Room.create!(
          matrix_room_id: "!abc:reddit.com",
          counterparty_username: "testuser",
        )
        seed_matrix_auth
        stubbed = stub_matrix_messages(room_id: "!abc:reddit.com", chunk: [], end_token: nil, from: "prev_cursor")

        get "/rooms/#{room.id}?from=prev_cursor"

        assert_requested(stubbed)
      end

      test "GET /rooms/:id surfaces a transcript error banner on non-auth Matrix errors" do
        room = Room.create!(
          matrix_room_id: "!abc:reddit.com",
          counterparty_username: "testuser",
        )
        seed_matrix_auth
        stub_request(:get, %r{/_matrix/client/v3/rooms/.+/messages})
          .to_return(status: 500, body: '{"errcode":"M_UNKNOWN","error":"boom"}')

        get "/rooms/#{room.id}"

        assert_equal(200, last_response.status)
        assert_match(%r{Matrix /messages call failed}, last_response.body)
      end

      # ---- /actions ----

      test "GET /actions renders the resync button" do
        get "/actions"

        assert_equal(200, last_response.status)
        assert_match(/Resync now/, last_response.body)
      end

      test "POST /actions/resync clears the sync checkpoint" do
        SyncCheckpoint.advance!("some_token")

        post "/actions/resync"

        assert_nil(SyncCheckpoint.next_batch_token)
      end

      test "POST /actions/resync shows a success notice" do
        post "/actions/resync"

        assert_match(/checkpoint cleared/i, last_response.body)
      end

      test "POST /actions/resync requires auth" do
        post "/logout"
        SyncCheckpoint.advance!("kept")

        post "/actions/resync"

        assert_equal(302, last_response.status)
        assert_equal("kept", SyncCheckpoint.next_batch_token)
      end

      # ---- /actions/reconcile ----

      test "GET /actions renders the reconcile button" do
        get "/actions"

        assert_match(/Reconcile now/, last_response.body)
      end

      test "POST /actions/reconcile delegates to Admin::Actions and shows a count banner" do
        Admin::Actions.any_instance.expects(:reconcile_channels!).returns(renamed: 2, skipped: 1, errors: 0)

        post "/actions/reconcile"

        assert_match(/2 renamed, 1 skipped, 0 errors/, last_response.body)
      end

      test "POST /actions/reconcile shows the error when config isn't complete" do
        Admin::Actions.any_instance
          .expects(:reconcile_channels!)
          .raises(Admin::Actions::NotConfiguredError, "Reconciler not configured — complete /settings first")

        post "/actions/reconcile"

        assert_match(/Reconciler not configured/, last_response.body)
      end

      # ---- /actions/full_resync ----

      test "GET /actions renders the full-resync button" do
        get "/actions"

        assert_match(/Full resync now/, last_response.body)
      end

      test "POST /actions/full_resync clears Room channel refs" do
        Room.create!(matrix_room_id: "!a:reddit.com", discord_channel_id: "111", last_event_id: "$x")

        post "/actions/full_resync"

        assert_nil(Room.first.discord_channel_id)
      end

      test "POST /actions/full_resync wipes PostedEvent and resets the checkpoint" do
        PostedEvent.record!(event_id: "$x", room_id: "!a:reddit.com")
        SyncCheckpoint.advance!("some_token")

        post "/actions/full_resync"

        assert_equal(0, PostedEvent.count)
        assert_nil(SyncCheckpoint.next_batch_token)
      end

      test "POST /actions/full_resync shows a result banner with counts" do
        Room.create!(matrix_room_id: "!a:reddit.com", discord_channel_id: "111")
        PostedEvent.record!(event_id: "$x", room_id: "!a:reddit.com")

        post "/actions/full_resync"

        assert_match(/cleared refs on 1 room/, last_response.body)
        assert_match(/wiped 1 posted-event record/, last_response.body)
      end

      test "POST /actions/full_resync requires auth" do
        post "/logout"
        Room.create!(matrix_room_id: "!a:reddit.com", discord_channel_id: "keep")

        post "/actions/full_resync"

        assert_equal(302, last_response.status)
        assert_equal("keep", Room.first.discord_channel_id)
      end

      test "the web-built reconciler wires a ChannelReorderer into the Poster" do
        # Regression: without this wiring full_resync + rebuild_all never
        # re-sort #dm-* channels — the supervisor-owned Poster has its own
        # reorderer but the web-initiated actions use a separate reconciler.
        seed_complete_bridge_config
        Admin::Actions.any_instance.stubs(:full_resync!).returns(
          channels_deleted: 0,
          channel_delete_errors: 0,
          rooms_reset: 0,
          events_cleared: 0,
          rebuilt: 0,
          rebuild_errors: 0,
        )
        Discord::ChannelReorderer.expects(:new).at_least_once.returns(stub("r", reorder!: nil))

        post "/actions/full_resync"
      end

      # ---- /rooms/:id/refresh ----

      test "GET /rooms renders a refresh button per row" do
        Room.create!(matrix_room_id: "!one:reddit.com", counterparty_username: "nothnnn", discord_channel_id: "123")

        get "/rooms"

        assert_match(%r{/rooms/\d+/refresh}, last_response.body)
      end

      test "POST /rooms/:id/refresh delegates and shows a result banner" do
        room = Room.create!(matrix_room_id: "!one:reddit.com", counterparty_username: "nothnnn", discord_channel_id: "123")
        Admin::Actions.any_instance.expects(:refresh_room!)
          .with(matrix_room_id: "!one:reddit.com")
          .returns(renamed: true, posted_attempted: 5)

        post "/rooms/#{room.id}/refresh"

        assert_match(/channel renamed/, last_response.body)
        assert_match(/5 event\(s\) re-examined/, last_response.body)
      end

      test "POST /rooms/:id/refresh shows an error when the room is unknown" do
        post "/rooms/9999/refresh"

        assert_match(/Room not found/, last_response.body)
      end

      private

      def seed_matrix_auth
        AppConfig.set("matrix_homeserver", "https://matrix.redditspace.com")
        AppConfig.set("matrix_user_id", "@t2_self:reddit.com")
        AuthState.update_token!(access_token: "tok", user_id: "@t2_self:reddit.com")
      end

      # Every key `Bridge::Application.configured?` checks, plus the auth
      # token. Used by tests that rely on `build_reconciler` returning a
      # real (non-nil) reconciler instead of short-circuiting.
      def seed_complete_bridge_config
        seed_matrix_auth
        AppConfig.set("discord_bot_token", "bot_abc")
        AppConfig.set("discord_guild_id", "g1")
        AppConfig.set("discord_dms_category_id", "c1")
        AppConfig.set("discord_admin_status_channel_id", "s1")
        AppConfig.set("discord_admin_logs_channel_id", "l1")
      end

      def stub_matrix_messages(room_id:, chunk:, end_token: nil, from: nil)
        query = { "dir" => "b", "limit" => "60" }
        query["from"] = from if from
        body = { "chunk" => chunk, "state" => [], "start" => "t_start" }
        body["end"] = end_token if end_token

        stub_request(
          :get,
          "https://matrix.redditspace.com/_matrix/client/v3/rooms/#{CGI.escape(room_id)}/messages",
        ).with(query: query).to_return(
          status: 200,
          body: JSON.generate(body),
          headers: { "Content-Type" => "application/json" },
        )
      end
    end
  end
end
