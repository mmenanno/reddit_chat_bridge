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
        post "/settings", discord_guild_id: "  1494755976241221705  "

        assert_equal("1494755976241221705", AppConfig.get("discord_guild_id"))
      end

      test "POST /settings triggers the provisioner when mode=auto and category is set" do
        Admin::Actions.any_instance.expects(:provision_system_channels!).returns([])

        post "/settings",
          discord_system_channels_mode: "auto",
          discord_system_channels_category_id: "1494756356119461968",
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
          discord_system_channels_category_id: "1494756356119461968"
        follow_redirect!

        assert_match(/2 channels created/, last_response.body)
        assert_match(/2 channels moved into the new category/, last_response.body)
      end

      test "POST /settings does not trigger the provisioner when mode=manual" do
        Admin::Actions.any_instance.expects(:provision_system_channels!).never

        post "/settings",
          discord_system_channels_mode: "manual",
          discord_system_channels_category_id: "1494756356119461968"
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
          discord_system_channels_category_id: "1494756356119461968"
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

      # ---- snowflake validation ----
      #
      # All Discord IDs are 64-bit snowflakes. A stale or mis-pasted value
      # silently wedges the sync loop (Poster logs "Invalid Form Body" on
      # every event), so catching a bad value at save time is cheaper than
      # debugging a running bridge.

      test "POST /settings rejects a non-numeric category ID with a named flash error" do
        AppConfig.set("discord_dms_category_id", "123456789012345678")

        post "/settings", discord_dms_category_id: "abc123"
        follow_redirect!

        assert_match(/Reddit DMs category ID/i, last_response.body)
        assert_match(/not a valid Discord ID/i, last_response.body)
        assert_equal("123456789012345678", AppConfig.get("discord_dms_category_id"))
      end

      test "POST /settings rejects a snowflake overflow (value > 2^63-1) without clobbering the stored value" do
        AppConfig.set("discord_dms_category_id", "1494756288171868311")

        post "/settings", discord_dms_category_id: "14947562881718683111"
        follow_redirect!

        assert_match(/Reddit DMs category ID/i, last_response.body)
        assert_equal("1494756288171868311", AppConfig.get("discord_dms_category_id"))
      end

      test "POST /settings accepts a blank snowflake (allows un-setting a field)" do
        post "/settings", discord_admin_commands_channel_id: ""

        follow_redirect!

        assert_match(/Settings saved/, last_response.body)
        assert_equal("", AppConfig.get("discord_admin_commands_channel_id"))
      end

      test "POST /settings accepts a valid 19-digit snowflake" do
        post "/settings", discord_guild_id: "1494755976241221705"

        follow_redirect!

        assert_equal("1494755976241221705", AppConfig.get("discord_guild_id"))
      end

      test "POST /settings accumulates validation errors across multiple fields" do
        post "/settings",
          discord_guild_id: "not_a_number",
          discord_dms_category_id: "99999999999999999999"
        follow_redirect!

        assert_match(/server \(guild\) ID/i, last_response.body)
        assert_match(/Reddit DMs category ID/i, last_response.body)
      end

      # ---- rebuild-on-save ----
      #
      # Discord::ChannelIndex and friends snapshot AppConfig at construction
      # time, so in-flight changes don't propagate to a running Application
      # without a graph rebuild. Without this, fixing a bad category ID
      # via /settings won't actually unblock the sync loop — you'd need a
      # container restart.

      test "POST /settings tears down and restarts the Application when already running so config changes take effect" do
        Bridge::Application.stubs(:running?).returns(true)
        Bridge::Application.expects(:shutdown!).once
        Bridge::Application.expects(:start_if_configured!).once

        post "/settings", discord_guild_id: "1494755976241221705"
      end

      test "POST /settings does not call shutdown! when the Application was not running" do
        Bridge::Application.stubs(:running?).returns(false)
        Bridge::Application.expects(:shutdown!).never
        Bridge::Application.expects(:start_if_configured!).once

        post "/settings", discord_guild_id: "1494755976241221705"
      end

      test "POST /settings does not rebuild when validation fails" do
        Bridge::Application.stubs(:running?).returns(true)
        Bridge::Application.expects(:shutdown!).never
        Bridge::Application.expects(:start_if_configured!).never

        post "/settings", discord_guild_id: "garbage"
      end
    end
  end
end
