# frozen_string_literal: true

require "test_helper"
require "admin/system_channel_provisioner"

module Admin
  class SystemChannelProvisionerTest < ActiveSupport::TestCase
    GUILD = "111111111111111111"
    CATEGORY = "222222222222222222"
    OTHER_CATEGORY = "999999999999999999"
    STATUS_ID = "301"
    LOGS_ID = "302"
    COMMANDS_ID = "303"
    MR_ID = "304"
    DEFAULT_ORDER = "status,logs,commands,message_requests"

    setup do
      @client = mock("DiscordClient")
      @journal = mock("Journal")
      @journal.stubs(:info)
      @provisioner = Admin::SystemChannelProvisioner.new(
        client: @client,
        guild_id: GUILD,
        journal: @journal,
      )
    end

    test "creates one channel per system slug under the configured category" do
      @client.expects(:create_channel)
        .with(guild_id: GUILD, name: "app-status", parent_id: CATEGORY, topic: anything)
        .returns(STATUS_ID)
      @client.expects(:create_channel)
        .with(guild_id: GUILD, name: "app-logs", parent_id: CATEGORY, topic: anything)
        .returns(LOGS_ID)
      @client.expects(:create_channel)
        .with(guild_id: GUILD, name: "commands", parent_id: CATEGORY, topic: anything)
        .returns(COMMANDS_ID)
      @client.expects(:create_channel)
        .with(guild_id: GUILD, name: "message-requests", parent_id: CATEGORY, topic: anything)
        .returns(MR_ID)
      @client.stubs(:reorder_channels)

      @provisioner.provision!(category_id: CATEGORY, order: DEFAULT_ORDER)
    end

    test "writes the newly-created channel IDs into AppConfig keyed by slug" do
      @client.stubs(:create_channel).with(has_entry(name: "app-status")).returns(STATUS_ID)
      @client.stubs(:create_channel).with(has_entry(name: "app-logs")).returns(LOGS_ID)
      @client.stubs(:create_channel).with(has_entry(name: "commands")).returns(COMMANDS_ID)
      @client.stubs(:create_channel).with(has_entry(name: "message-requests")).returns(MR_ID)
      @client.stubs(:reorder_channels)

      @provisioner.provision!(category_id: CATEGORY, order: DEFAULT_ORDER)

      expected = {
        "discord_admin_status_channel_id" => STATUS_ID,
        "discord_admin_logs_channel_id" => LOGS_ID,
        "discord_admin_commands_channel_id" => COMMANDS_ID,
        "discord_message_requests_channel_id" => MR_ID,
      }

      assert_equal(expected, AppConfig.fetch_many(expected.keys))
    end

    test "reorders channels according to the default order after provisioning" do
      @client.stubs(:create_channel).with(has_entry(name: "app-status")).returns(STATUS_ID)
      @client.stubs(:create_channel).with(has_entry(name: "app-logs")).returns(LOGS_ID)
      @client.stubs(:create_channel).with(has_entry(name: "commands")).returns(COMMANDS_ID)
      @client.stubs(:create_channel).with(has_entry(name: "message-requests")).returns(MR_ID)
      @client.expects(:reorder_channels).with(
        guild_id: GUILD,
        positions: [
          { id: STATUS_ID, position: 0 },
          { id: LOGS_ID, position: 1 },
          { id: COMMANDS_ID, position: 2 },
          { id: MR_ID, position: 3 },
        ],
      )

      @provisioner.provision!(category_id: CATEGORY, order: DEFAULT_ORDER)
    end

    test "adopts existing channels by moving them to the new category" do
      AppConfig.set("discord_admin_status_channel_id", STATUS_ID)
      AppConfig.set("discord_admin_logs_channel_id", LOGS_ID)
      AppConfig.set("discord_admin_commands_channel_id", COMMANDS_ID)
      AppConfig.set("discord_message_requests_channel_id", MR_ID)

      stub_get_channel(STATUS_ID, parent: OTHER_CATEGORY)
      stub_get_channel(LOGS_ID, parent: OTHER_CATEGORY)
      stub_get_channel(COMMANDS_ID, parent: OTHER_CATEGORY)
      stub_get_channel(MR_ID, parent: OTHER_CATEGORY)

      @client.expects(:update_channel).with(channel_id: STATUS_ID, parent_id: CATEGORY)
      @client.expects(:update_channel).with(channel_id: LOGS_ID, parent_id: CATEGORY)
      @client.expects(:update_channel).with(channel_id: COMMANDS_ID, parent_id: CATEGORY)
      @client.expects(:update_channel).with(channel_id: MR_ID, parent_id: CATEGORY)
      @client.expects(:create_channel).never
      @client.expects(:reorder_channels)

      @provisioner.provision!(category_id: CATEGORY, order: DEFAULT_ORDER)

      assert_equal(STATUS_ID, AppConfig.get("discord_admin_status_channel_id"))
    end

    test "leaves channels in place when already under the target category" do
      AppConfig.set("discord_admin_status_channel_id", STATUS_ID)
      AppConfig.set("discord_admin_logs_channel_id", LOGS_ID)
      AppConfig.set("discord_admin_commands_channel_id", COMMANDS_ID)
      AppConfig.set("discord_message_requests_channel_id", MR_ID)

      stub_get_channel(STATUS_ID, parent: CATEGORY)
      stub_get_channel(LOGS_ID, parent: CATEGORY)
      stub_get_channel(COMMANDS_ID, parent: CATEGORY)
      stub_get_channel(MR_ID, parent: CATEGORY)

      @client.expects(:create_channel).never
      @client.expects(:update_channel).never
      @client.expects(:reorder_channels)

      @provisioner.provision!(category_id: CATEGORY, order: DEFAULT_ORDER)
    end

    test "mixes adopt and create when some IDs are blank" do
      AppConfig.set("discord_admin_status_channel_id", STATUS_ID)
      AppConfig.set("discord_admin_logs_channel_id", LOGS_ID)
      # commands + message_requests left blank

      stub_get_channel(STATUS_ID, parent: OTHER_CATEGORY)
      stub_get_channel(LOGS_ID, parent: OTHER_CATEGORY)

      @client.expects(:update_channel).with(channel_id: STATUS_ID, parent_id: CATEGORY)
      @client.expects(:update_channel).with(channel_id: LOGS_ID, parent_id: CATEGORY)
      @client.expects(:create_channel)
        .with(guild_id: GUILD, name: "commands", parent_id: CATEGORY, topic: anything)
        .returns(COMMANDS_ID)
      @client.expects(:create_channel)
        .with(guild_id: GUILD, name: "message-requests", parent_id: CATEGORY, topic: anything)
        .returns(MR_ID)
      @client.expects(:reorder_channels)

      @provisioner.provision!(category_id: CATEGORY, order: DEFAULT_ORDER)

      assert_equal(COMMANDS_ID, AppConfig.get("discord_admin_commands_channel_id"))
      assert_equal(MR_ID, AppConfig.get("discord_message_requests_channel_id"))
    end

    test "falls through to create when stored ID is stale (404 on get_channel)" do
      AppConfig.set("discord_admin_status_channel_id", "gone_stale")
      fresh_id = "new_status_999"

      @client.expects(:get_channel).with("gone_stale").raises(Discord::NotFound, "Unknown Channel")
      @client.stubs(:create_channel).with(has_entry(name: "app-status")).returns(fresh_id)
      @client.stubs(:create_channel).with(has_entry(name: "app-logs")).returns(LOGS_ID)
      @client.stubs(:create_channel).with(has_entry(name: "commands")).returns(COMMANDS_ID)
      @client.stubs(:create_channel).with(has_entry(name: "message-requests")).returns(MR_ID)
      @client.stubs(:reorder_channels)

      @provisioner.provision!(category_id: CATEGORY, order: DEFAULT_ORDER)

      assert_equal(fresh_id, AppConfig.get("discord_admin_status_channel_id"))
    end

    test "honours custom order in reorder positions" do
      @client.stubs(:create_channel).with(has_entry(name: "app-status")).returns(STATUS_ID)
      @client.stubs(:create_channel).with(has_entry(name: "app-logs")).returns(LOGS_ID)
      @client.stubs(:create_channel).with(has_entry(name: "commands")).returns(COMMANDS_ID)
      @client.stubs(:create_channel).with(has_entry(name: "message-requests")).returns(MR_ID)
      @client.expects(:reorder_channels).with(
        guild_id: GUILD,
        positions: [
          { id: MR_ID, position: 0 },
          { id: COMMANDS_ID, position: 1 },
          { id: LOGS_ID, position: 2 },
          { id: STATUS_ID, position: 3 },
        ],
      )

      @provisioner.provision!(
        category_id: CATEGORY,
        order: "message_requests,commands,logs,status",
      )
    end

    test "drops unknown slugs and appends missing slugs in default order" do
      @client.stubs(:create_channel).returns(STATUS_ID, LOGS_ID, COMMANDS_ID, MR_ID)
      # Order contains one known slug + one garbage slug; the rest get appended
      # in the canonical order (logs, commands, message_requests).
      @client.expects(:reorder_channels).with(
        guild_id: GUILD,
        positions: [
          { id: STATUS_ID, position: 0 },
          { id: LOGS_ID, position: 1 },
          { id: COMMANDS_ID, position: 2 },
          { id: MR_ID, position: 3 },
        ],
      )

      @provisioner.provision!(
        category_id: CATEGORY,
        order: "status,nope_not_a_slug",
      )
    end

    test "bubbles Discord::AuthError" do
      @client.expects(:create_channel).raises(Discord::AuthError, "Missing Permissions")

      assert_raises(Discord::AuthError) do
        @provisioner.provision!(category_id: CATEGORY, order: DEFAULT_ORDER)
      end
    end

    private

    def stub_get_channel(id, parent:)
      @client.stubs(:get_channel).with(id).returns({ "id" => id, "parent_id" => parent })
    end
  end
end
