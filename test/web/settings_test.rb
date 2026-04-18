# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "bridge/web/app"

module Bridge
  module Web
    class SettingsTest < ActiveSupport::TestCase
      include Rack::Test::Methods

      def app
        App
      end

      setup do
        AdminUser.create_with_password!(username: "michael", password: "hunter2hunter2")
        post("/login", username: "michael", password: "hunter2hunter2")
      end

      test "GET /settings renders the form" do
        get "/settings"

        assert_equal(200, last_response.status)
        assert_match(/Discord bot token/, last_response.body)
        assert_match(/Matrix homeserver/, last_response.body)
      end

      test "GET /settings pre-fills fields from AppConfig" do
        AppConfig.set("discord_guild_id", "999000")

        get "/settings"

        assert_match(/value="999000"/, last_response.body)
      end

      test "POST /settings persists every known field to AppConfig" do
        post "/settings",
          matrix_homeserver: "https://matrix.redditspace.com",
          matrix_user_id: "@t2_abc:reddit.com",
          discord_bot_token: "tok_789",
          discord_guild_id: "111",
          discord_dms_category_id: "222",
          discord_admin_status_channel_id: "333",
          discord_admin_logs_channel_id: "444",
          discord_admin_commands_channel_id: "555"

        assert_equal(200, last_response.status)
        assert_equal("tok_789", AppConfig.get("discord_bot_token"))
        assert_equal("222", AppConfig.get("discord_dms_category_id"))
      end

      test "POST /settings shows a success notice after saving" do
        post "/settings"

        assert_match(/Settings saved/, last_response.body)
      end

      test "POST /settings is reachable only when authenticated" do
        post "/logout"

        post "/settings", discord_guild_id: "leaked"

        assert_equal(302, last_response.status)
        assert_equal("/login", URI(last_response.location).path)
        assert_nil(AppConfig.get("discord_guild_id"))
      end

      test "POST /settings strips whitespace around submitted values" do
        post "/settings", discord_guild_id: "  pad  "

        assert_equal("pad", AppConfig.get("discord_guild_id"))
      end
    end
  end
end
