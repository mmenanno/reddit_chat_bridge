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
    end
  end
end
