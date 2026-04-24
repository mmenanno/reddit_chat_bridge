# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "bridge/application"
require "bridge/build_info"
require "bridge/web/app"

module Bridge
  module Web
    class GuideTest < ActiveSupport::TestCase
      include Rack::Test::Methods

      def app
        App
      end

      setup do
        AdminUser.create_with_password!(username: "michael", password: "hunter2hunter2")
        post "/login", username: "michael", password: "hunter2hunter2"
      end

      # ---- GET /guide/bot-setup renders ----

      test "returns 200" do
        get "/guide/bot-setup"

        assert_equal(200, last_response.status)
      end

      test "renders the page header" do
        get "/guide/bot-setup"

        assert_match(/Setup guide/, last_response.body)
      end

      test "renders each of the five step titles in order" do
        get "/guide/bot-setup"

        # One regex covering all five h2s in render order, so any drift in the
        # view's chapter list fails this single test instead of producing
        # separate failures per title.
        ordered = /Stand up the dedicated server.*Mint the app, mint the bot.*Invite the bot to your server.*Copy the IDs into the bridge.*Prove the bot can talk/m

        assert_match(ordered, last_response.body)
      end

      test "shows the pre-built invite URL when application ID is already saved" do
        AppConfig.set("discord_application_id", "1234567890123456789")

        get "/guide/bot-setup"

        assert_match(
          %r{https://discord.com/api/oauth2/authorize\?client_id=1234567890123456789},
          last_response.body,
        )
      end

      test "shows an empty invite placeholder when application ID is missing" do
        get "/guide/bot-setup"

        assert_match(/Enter an Application ID above to generate/, last_response.body)
      end

      # ---- GUIDE_INVITE_PERMISSIONS bitmask ----

      test "invite permissions bitmask matches Discord's required set" do
        # Derivation lives in app.rb; this locks the number so a stray edit
        # to the constant doesn't silently change the OAuth2 scope the
        # invite URL requests. Recompute if the bridge ever legitimately
        # needs another permission bit.
        expected = (1 << 4) | (1 << 11) | (1 << 13) | (1 << 14) |
          (1 << 15) | (1 << 16) | (1 << 29) | (1 << 31)

        assert_equal(expected, App::GUIDE_INVITE_PERMISSIONS)
      end

      # ---- settings page links into the guide ----

      test "settings page header links to the interactive guide" do
        get "/settings"

        assert_match(%r{href="/guide/bot-setup"}, last_response.body)
      end

      # ---- dashboard lists the guide as a chapter entry ----

      test "dashboard chapter index includes the guide" do
        get "/"

        body = last_response.body

        assert_match(%r{href="/guide/bot-setup"}, body)
        assert_match(/Setup guide/, body)
      end

      # ---- step status derivation ----

      test "all steps pending when AppConfig is empty" do
        helpers = App.new!

        statuses = helpers.guide_bot_setup_steps.map { |s| s[:status] }

        assert_equal([:pending, :pending, :pending, :pending, :pending], statuses)
      end

      test "steps reflect populated AppConfig in auto mode" do
        AppConfig.set("discord_bot_token", "bot-token-xyz")
        AppConfig.set("discord_application_id", "1234567890123456789")
        AppConfig.set("discord_guild_id", "9999999999999999999")
        AppConfig.set("discord_dms_category_id", "1111")
        AppConfig.set("discord_system_channels_mode", "auto")
        AppConfig.set("discord_system_channels_category_id", "2222")

        statuses = App.new!.guide_bot_setup_steps.map { |s| s[:status] }

        assert_equal([:ok, :ok, :ok, :ok, :ok], statuses)
      end

      test "manual mode requires every channel ID before step 4 flips to ok" do
        AppConfig.set("discord_system_channels_mode", "manual")
        AppConfig.set("discord_dms_category_id", "1111")
        AppConfig.set("discord_admin_status_channel_id", "aaa")
        AppConfig.set("discord_admin_logs_channel_id", "bbb")
        AppConfig.set("discord_admin_commands_channel_id", "ccc")
        # discord_message_requests_channel_id intentionally left blank to prove
        # manual-mode strictness: all four must be set.

        steps = App.new!.guide_bot_setup_steps

        assert_equal(:pending, steps[3][:status])
        assert_equal(1, steps[3][:missing_count])

        AppConfig.set("discord_message_requests_channel_id", "ddd")

        assert_equal(:ok, App.new!.guide_bot_setup_steps[3][:status])
      end

      # ---- invite URL helper ----

      test "guide_invite_url returns nil for blank input" do
        assert_nil(App.new!.guide_invite_url(""))
        assert_nil(App.new!.guide_invite_url("   "))
        assert_nil(App.new!.guide_invite_url(nil))
      end

      test "guide_invite_url builds a valid Discord OAuth2 URL" do
        url = App.new!.guide_invite_url("1234567890123456789")

        assert_includes(url, "client_id=1234567890123456789")
        assert_includes(url, "scope=bot%20applications.commands")
        assert_includes(url, "permissions=#{App::GUIDE_INVITE_PERMISSIONS}")
      end
    end
  end
end
