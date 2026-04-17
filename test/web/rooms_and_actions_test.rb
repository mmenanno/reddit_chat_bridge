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

      def setup
        super
        AdminUser.create_with_password!(username: "michael", password: "hunter2hunter2")
        post("/login", username: "michael", password: "hunter2hunter2")
      end

      # ---- /rooms ----

      test "GET /rooms with no bridged rooms shows an empty-state message" do
        get "/rooms"

        assert_equal(200, last_response.status)
        assert_match(/No rooms yet/, last_response.body)
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
        assert_match(%r{<code>!one:reddit\.com</code>}, last_response.body)
      end

      test "GET /rooms marks rooms without a discord channel as 'not created yet'" do
        Room.create!(
          matrix_room_id: "!one:reddit.com",
          counterparty_username: "nothnnn",
        )

        get "/rooms"

        assert_match(/not created yet/, last_response.body)
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
    end
  end
end
