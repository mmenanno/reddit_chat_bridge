# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "bridge/application"
require "bridge/build_info"
require "bridge/web/app"
require "admin/actions"
require "discord/client"

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
      end

      test "GET /settings pre-fills fields from AppConfig" do
        AppConfig.set("discord_guild_id", "999000")

        get "/settings"

        assert_match(/value="999000"/, last_response.body)
      end

      test "POST /settings persists every known field to AppConfig and redirects" do
        post "/settings",
          discord_bot_token: "tok_789",
          discord_guild_id: "111",
          discord_dms_category_id: "222",
          discord_admin_status_channel_id: "333",
          discord_admin_logs_channel_id: "444",
          discord_admin_commands_channel_id: "555"

        assert_equal("/settings", URI(last_response.location).path)
        assert_equal("tok_789", AppConfig.get("discord_bot_token"))
        assert_equal("222", AppConfig.get("discord_dms_category_id"))
      end

      test "POST /settings shows a success notice after saving" do
        post "/settings"
        follow_redirect!

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

      test "POST /settings triggers the provisioner when mode=auto and category is set" do
        Admin::Actions.any_instance.expects(:provision_system_channels!).returns([])

        post "/settings",
          discord_system_channels_mode: "auto",
          discord_system_channels_category_id: "cat_42",
          discord_system_channels_order: "status,logs,commands,message_requests"
      end

      test "POST /settings flashes a summary of what the provisioner did" do
        outcomes = [
          { slug: "status",           outcome: :moved,   id: "aaa", position: 0 },
          { slug: "logs",             outcome: :moved,   id: "bbb", position: 1 },
          { slug: "commands",         outcome: :created, id: "ccc", position: 2 },
          { slug: "message_requests", outcome: :created, id: "ddd", position: 3 },
        ]
        Admin::Actions.any_instance.expects(:provision_system_channels!).returns(outcomes)

        post "/settings",
          discord_system_channels_mode: "auto",
          discord_system_channels_category_id: "cat_42"
        follow_redirect!

        assert_match(/2 channels created/, last_response.body)
        assert_match(/2 channels moved into the new category/, last_response.body)
      end

      test "POST /settings does not trigger the provisioner when mode=manual" do
        Admin::Actions.any_instance.expects(:provision_system_channels!).never

        post "/settings",
          discord_system_channels_mode: "manual",
          discord_system_channels_category_id: "cat_42"
      end

      test "POST /settings does not trigger the provisioner when the category is blank" do
        Admin::Actions.any_instance.expects(:provision_system_channels!).never

        post "/settings",
          discord_system_channels_mode: "auto",
          discord_system_channels_category_id: ""
      end

      test "POST /settings surfaces Discord errors from the provisioner in a flash notice" do
        Admin::Actions.any_instance.expects(:provision_system_channels!)
          .raises(Discord::AuthError, "Missing Permissions")

        post "/settings",
          discord_system_channels_mode: "auto",
          discord_system_channels_category_id: "cat_42"
        follow_redirect!

        assert_match(/Missing Permissions/, last_response.body)
      end

      test "POST /settings persists the system-channels order" do
        post "/settings",
          discord_system_channels_order: "message_requests,commands,logs,status"

        assert_equal(
          "message_requests,commands,logs,status",
          AppConfig.get("discord_system_channels_order"),
        )
      end

      test "GET /settings defaults the system-channels mode to auto on fresh installs" do
        get "/settings"

        # The segmented toggle renders a radio input for each mode; the default
        # should mark Auto as checked.
        assert_match(
          /<input[^>]*name="discord_system_channels_mode"[^>]*value="auto"[^>]*checked/i,
          last_response.body,
        )
      end
    end
  end
end
