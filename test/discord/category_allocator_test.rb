# frozen_string_literal: true

require "test_helper"
require "discord/client"
require "discord/category_allocator"

module Discord
  class CategoryAllocatorTest < ActiveSupport::TestCase
    GUILD = "111111111111111111"
    PRIMARY = "222222222222222222"
    SPILLOVER_KEY = "discord_dms_spillover_category_ids"
    OVERWRITES = [{ "id" => "everyone", "type" => 0, "allow" => "0", "deny" => "1024" }].freeze

    setup do
      @client = mock("Discord::Client")
      @journal = mock("Journal")
      @allocator = Discord::CategoryAllocator.new(
        client: @client,
        guild_id: GUILD,
        primary_category_id: PRIMARY,
        journal: @journal,
      )
    end

    def category_full_error
      Discord::BadRequest.new(
        "Invalid Form Body (parent_id: CHANNEL_PARENT_MAX_CHANNELS: " \
        "Maximum number of channels in category reached (50))",
      )
    end

    test "creates the channel under the primary category when it is not full" do
      @client.expects(:create_channel)
        .with(guild_id: GUILD, name: "dm-foo", parent_id: PRIMARY, topic: "t")
        .returns("chan1")

      assert_equal("chan1", @allocator.create_channel(name: "dm-foo", topic: "t"))
    end

    test "targets the last spillover category when one already exists" do
      AppConfig.set(SPILLOVER_KEY, "cat2,cat3")
      @client.expects(:create_channel)
        .with(guild_id: GUILD, name: "dm-foo", parent_id: "cat3", topic: nil)
        .returns("chan")

      assert_equal("chan", @allocator.create_channel(name: "dm-foo", topic: nil))
    end

    test "creates a spillover category and retries when the target is full" do
      seq = sequence("spillover")
      @client.expects(:create_channel)
        .with(guild_id: GUILD, name: "dm-foo", parent_id: PRIMARY, topic: "t")
        .raises(category_full_error).in_sequence(seq)
      @client.expects(:get_channel).with(PRIMARY)
        .returns("name" => "Reddit DMs", "permission_overwrites" => OVERWRITES).in_sequence(seq)
      # Copies the primary category's overwrites so the spillover stays private.
      @client.expects(:create_category)
        .with(guild_id: GUILD, name: "Reddit DMs 2", permission_overwrites: OVERWRITES)
        .returns("cat2").in_sequence(seq)
      @client.expects(:create_channel)
        .with(guild_id: GUILD, name: "dm-foo", parent_id: "cat2", topic: "t")
        .returns("chan2").in_sequence(seq)
      @journal.expects(:info)

      assert_equal("chan2", @allocator.create_channel(name: "dm-foo", topic: "t"))
      assert_equal("cat2", AppConfig.get(SPILLOVER_KEY))
    end

    test "names the next spillover from the primary name and the category count" do
      AppConfig.set(SPILLOVER_KEY, "cat2")
      @client.expects(:create_channel).with(has_entry(parent_id: "cat2")).raises(category_full_error)
      @client.expects(:get_channel).with(PRIMARY).returns("name" => "Inbox")
      @client.expects(:create_category).with(guild_id: GUILD, name: "Inbox 3", permission_overwrites: nil).returns("cat3")
      @client.expects(:create_channel).with(has_entry(parent_id: "cat3")).returns("chan")
      @journal.stubs(:info)

      @allocator.create_channel(name: "dm-foo", topic: nil)

      assert_equal("cat2,cat3", AppConfig.get(SPILLOVER_KEY))
    end

    test "falls back to 'Reddit DMs' when the primary name can't be fetched" do
      @client.expects(:create_channel).with(has_entry(parent_id: PRIMARY)).raises(category_full_error)
      @client.expects(:get_channel).with(PRIMARY).raises(Discord::NotFound.new("gone"))
      @client.expects(:create_category).with(guild_id: GUILD, name: "Reddit DMs 2", permission_overwrites: nil).returns("cat2")
      @client.expects(:create_channel).with(has_entry(parent_id: "cat2")).returns("chan")
      @journal.stubs(:info)

      @allocator.create_channel(name: "dm-foo", topic: nil)
    end

    test "propagates a BadRequest that is not the category-full error" do
      @client.expects(:create_channel).raises(Discord::BadRequest.new("Invalid Form Body (name: too long)"))
      @client.expects(:create_category).never

      assert_raises(Discord::BadRequest) { @allocator.create_channel(name: "dm-foo", topic: nil) }
    end

    test "alerts critically and re-raises when the guild channel cap blocks spillover" do
      @client.expects(:create_channel).with(has_entry(parent_id: PRIMARY)).raises(category_full_error)
      @client.expects(:get_channel).with(PRIMARY).returns("name" => "Reddit DMs")
      @client.expects(:create_category).raises(Discord::BadRequest.new("Maximum number of guild channels reached (500)"))
      @journal.expects(:critical)

      assert_raises(Discord::BadRequest) { @allocator.create_channel(name: "dm-foo", topic: nil) }
    end

    test "propagates AuthError from channel creation" do
      @client.expects(:create_channel).raises(Discord::AuthError.new("403"))

      assert_raises(Discord::AuthError) { @allocator.create_channel(name: "dm-foo", topic: nil) }
    end

    test "alerts about Manage Roles and re-raises when spillover category create is forbidden" do
      @client.expects(:create_channel).with(has_entry(parent_id: PRIMARY)).raises(category_full_error)
      @client.expects(:get_channel).with(PRIMARY).returns("name" => "Reddit DMs", "permission_overwrites" => OVERWRITES)
      @client.expects(:create_category).raises(Discord::AuthError.new("Missing Permissions"))
      @journal.expects(:critical).with(regexp_matches(/Manage Roles/), has_key(:source))

      assert_raises(Discord::AuthError) { @allocator.create_channel(name: "dm-foo", topic: nil) }
    end

    test "warns and re-raises without creating a category when spillover is disabled" do
      AppConfig.set("discord_dms_spillover_enabled", "false")
      @client.expects(:create_channel).with(has_entry(parent_id: PRIMARY)).raises(category_full_error)
      @client.expects(:create_category).never
      @journal.expects(:warn)

      assert_raises(Discord::BadRequest) { @allocator.create_channel(name: "dm-foo", topic: nil) }
    end
  end
end
