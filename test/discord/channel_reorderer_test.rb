# frozen_string_literal: true

require "test_helper"
require "discord/client"
require "discord/channel_reorderer"

module Discord
  class ChannelReordererTest < ActiveSupport::TestCase
    GUILD = "111111111111"

    setup do
      @client = mock("DiscordClient")
      @reorderer = ChannelReorderer.new(client: @client, guild_id: GUILD)
    end

    test "sends active rooms ordered most-recent-first to the bulk reorder endpoint" do
      make_room("old", activity: 3.hours.ago, channel: "chan_old")
      make_room("mid", activity: 1.hour.ago, channel: "chan_mid")
      make_room("new", activity: 5.minutes.ago, channel: "chan_new")
      @client.expects(:reorder_channels).with(
        guild_id: GUILD,
        positions: [
          { id: "chan_new", position: 0 },
          { id: "chan_mid", position: 1 },
          { id: "chan_old", position: 2 },
        ],
      )

      @reorderer.reorder!
    end

    test "rooms with no activity stamp sort to the bottom without blocking the reorder" do
      make_room("active", activity: 10.minutes.ago, channel: "chan_active")
      make_room("silent", activity: nil, channel: "chan_silent")
      @client.expects(:reorder_channels).with(
        guild_id: GUILD,
        positions: [
          { id: "chan_active", position: 0 },
          { id: "chan_silent", position: 1 },
        ],
      )

      @reorderer.reorder!
    end

    test "skips archived, terminated, and channel-less rooms" do
      make_room("alive", activity: 1.minute.ago, channel: "chan_alive")
      make_room("archived", activity: 2.minutes.ago, channel: "chan_archived", archived_at: 1.hour.ago)
      make_room("terminated", activity: 3.minutes.ago, channel: "chan_terminated", terminated_at: 1.hour.ago)
      make_room("pending", activity: 4.minutes.ago, channel: nil)
      @client.expects(:reorder_channels).with(
        guild_id: GUILD,
        positions: [{ id: "chan_alive", position: 0 }],
      )

      @reorderer.reorder!
    end

    test "no-ops when no qualifying rooms exist" do
      @client.expects(:reorder_channels).never

      @reorderer.reorder!
    end

    test "no-ops when the guild id isn't configured" do
      make_room("alive", activity: 1.minute.ago, channel: "chan_alive")
      unconfigured = ChannelReorderer.new(client: @client, guild_id: "")
      @client.expects(:reorder_channels).never

      unconfigured.reorder!
    end

    test "swallows and logs Discord errors so the caller's flow isn't aborted" do
      make_room("alive", activity: 1.minute.ago, channel: "chan_alive")
      logger = mock("Logger")
      logger.expects(:warn).with(regexp_matches(/channel reorder failed/i))
      reorderer = ChannelReorderer.new(client: @client, guild_id: GUILD, logger: logger)
      @client.expects(:reorder_channels).raises(Discord::ServerError, "503")

      assert_nothing_raised { reorderer.reorder! }
    end

    private

    def make_room(name, activity:, channel:, archived_at: nil, terminated_at: nil)
      Room.create!(
        matrix_room_id: "!#{name}:reddit.com",
        counterparty_username: name,
        discord_channel_id: channel,
        last_activity_at: activity,
        archived_at: archived_at,
        terminated_at: terminated_at,
      )
    end
  end
end
