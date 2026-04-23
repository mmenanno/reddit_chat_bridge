# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "bridge/web/app"

module Bridge
  module Web
    class AppTest < ActiveSupport::TestCase
      include Rack::Test::Methods

      def app
        App
      end

      # ---- /health ----

      test "GET /health returns 200 with ok status and no auth required" do
        get "/health"

        assert_equal(200, last_response.status)
        body = JSON.parse(last_response.body)

        assert_equal("ok", body["status"])
      end

      test "GET /health reports matrix status as ok when not paused" do
        get "/health"

        assert_equal("ok", JSON.parse(last_response.body)["matrix"])
      end

      test "GET /health reports matrix status as paused when AuthState is paused" do
        AuthState.mark_failure!("M_UNKNOWN_TOKEN")

        get "/health"

        assert_equal("paused", JSON.parse(last_response.body)["matrix"])
      end

      # ---- first-run redirects ----

      test "unauthenticated GET / redirects to /setup when no admin exists" do
        get "/"

        assert_equal(302, last_response.status)
        assert_equal("/setup", URI(last_response.location).path)
      end

      test "unauthenticated GET / redirects to /login when an admin exists" do
        AdminUser.create_with_password!(username: "michael", password: "hunter2hunter2")

        get "/"

        assert_equal(302, last_response.status)
        assert_equal("/login", URI(last_response.location).path)
      end

      # ---- /setup ----

      test "GET /setup renders the wizard when no admin exists" do
        get "/setup"

        assert_equal(200, last_response.status)
        assert_match(/Create admin account/, last_response.body)
      end

      test "GET /setup redirects to / once an admin has been created" do
        AdminUser.create_with_password!(username: "michael", password: "hunter2hunter2")

        get "/setup"

        assert_equal(302, last_response.status)
        assert_equal("/", URI(last_response.location).path)
      end

      test "POST /setup creates the admin and logs them in" do
        post "/setup", username: "michael", password: "hunter2hunter2"

        assert_equal(302, last_response.status)
        assert_equal("/", URI(last_response.location).path)
        assert_equal(1, AdminUser.count)
      end

      test "POST /setup with a too-short password redirects back to /setup with a flash error" do
        post "/setup", username: "michael", password: "short"

        assert_equal("/setup", URI(last_response.location).path)
        follow_redirect!

        assert_match(/Password too short/, last_response.body)
        assert_equal(0, AdminUser.count)
      end

      # ---- /login + /logout ----

      test "POST /login with correct credentials redirects to /" do
        AdminUser.create_with_password!(username: "michael", password: "hunter2hunter2")

        post "/login", username: "michael", password: "hunter2hunter2"

        assert_equal(302, last_response.status)
        assert_equal("/", URI(last_response.location).path)
      end

      test "POST /login with wrong credentials redirects back to /login with a flash error" do
        AdminUser.create_with_password!(username: "michael", password: "hunter2hunter2")

        post "/login", username: "michael", password: "wrong-password"

        assert_equal("/login", URI(last_response.location).path)
        follow_redirect!

        assert_match(/Invalid username or password/, last_response.body)
      end

      test "POST /logout clears the session and redirects to /login" do
        AdminUser.create_with_password!(username: "michael", password: "hunter2hunter2")
        post "/login", username: "michael", password: "hunter2hunter2"

        post "/logout"

        assert_equal(302, last_response.status)
        assert_equal("/login", URI(last_response.location).path)
      end

      # ---- authenticated dashboard ----

      test "GET / after login renders the dashboard" do
        AdminUser.create_with_password!(username: "michael", password: "hunter2hunter2")
        post "/login", username: "michael", password: "hunter2hunter2"

        get "/"

        assert_equal(200, last_response.status)
        assert_match(/Dashboard/, last_response.body)
      end
    end
  end
end
