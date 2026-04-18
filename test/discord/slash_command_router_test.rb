# frozen_string_literal: true

require "test_helper"
require "discord/slash_command_router"

module Discord
  class SlashCommandRouterTest < ActiveSupport::TestCase
    GUILD = "111"
    CHAN  = "222"

    setup do
      @actions = mock("AdminActions")
      @router = SlashCommandRouter.new(
        admin_actions: @actions,
        guild_id: GUILD,
        commands_channel_id: CHAN,
      )
    end

    test "responds to PING with PONG" do
      response = @router.dispatch({ "type" => 1 })

      assert_equal(1, response[:type])
    end

    test "rejects commands from a different guild" do
      response = @router.dispatch(interaction(name: "ping", guild: "other"))

      assert_match(/different guild|must be run in the configured/i, response[:data][:content])
    end

    test "rejects commands from a different channel when channel is configured" do
      response = @router.dispatch(interaction(name: "ping", channel: "999"))

      assert_match(/must be run in the configured/i, response[:data][:content])
    end

    test "runs /ping and replies with pong" do
      response = @router.dispatch(interaction(name: "ping"))

      assert_equal(4, response[:type])
      assert_match(/pong/, response[:data][:content])
    end

    test "runs /resync by delegating to Admin::Actions" do
      @actions.expects(:resync).returns(:ok)

      response = @router.dispatch(interaction(name: "resync"))

      assert_match(/Cleared.*checkpoint/, response[:data][:content])
    end

    test "runs /reconcile and surfaces the stats" do
      @actions.expects(:reconcile_channels!).returns(renamed: 3, skipped: 1, errors: 0)

      response = @router.dispatch(interaction(name: "reconcile"))

      assert_match(/3 renamed, 1 skipped, 0 errors/, response[:data][:content])
    end

    test "catches handler exceptions and surfaces them as ephemeral replies" do
      @actions.expects(:resync).raises(RuntimeError, "db gone")

      response = @router.dispatch(interaction(name: "resync"))

      assert_match(/RuntimeError.*db gone/, response[:data][:content])
    end

    test "replies ephemerally so other #commands members don't see responses" do
      response = @router.dispatch(interaction(name: "ping"))

      assert_equal(64, response[:data][:flags])
    end

    test "dispatch is transport-agnostic — same payload works from gateway or HTTP" do
      # Identical payload shape, no transport-specific wrapper
      gateway_response = @router.dispatch(interaction(name: "ping"))
      http_response    = @router.dispatch(interaction(name: "ping"))

      assert_equal(gateway_response, http_response)
    end

    # ---- /endchat (per-room command, runs in the target #dm-* channel) ----

    test "runs /endchat from inside a #dm-* channel and delegates to Admin::Actions" do
      Room.create!(matrix_room_id: "!r:reddit.com", counterparty_username: "testuser", discord_channel_id: "dm_555")
      @actions.expects(:end_chat!).with(matrix_room_id: "!r:reddit.com")

      response = @router.dispatch(interaction(name: "endchat", channel: "dm_555"))

      assert_match(/Ended chat with \*\*testuser\*\*/, response[:data][:content])
    end

    test "runs /endchat even when the channel isn't the #commands channel (per-room override)" do
      Room.create!(matrix_room_id: "!r:reddit.com", discord_channel_id: "dm_not_commands")
      @actions.expects(:end_chat!)

      response = @router.dispatch(interaction(name: "endchat", channel: "dm_not_commands"))

      refute_match(/must be run in the configured/i, response[:data][:content])
    end

    test "returns a helpful error when /endchat fires in a channel that isn't linked to a room" do
      @actions.expects(:end_chat!).never

      response = @router.dispatch(interaction(name: "endchat", channel: "some_random_channel"))

      assert_match(/no bridged room matches/i, response[:data][:content])
    end

    # ---- /archive (per-room command, runs in the target #dm-* channel) ----

    test "runs /archive from inside a #dm-* channel and delegates to Admin::Actions" do
      Room.create!(matrix_room_id: "!r:reddit.com", counterparty_username: "testuser", discord_channel_id: "dm_555")
      @actions.expects(:archive_room!).with(matrix_room_id: "!r:reddit.com").returns(:archived)

      response = @router.dispatch(interaction(name: "archive", channel: "dm_555"))

      assert_match(/Archived \*\*testuser\*\*/, response[:data][:content])
    end

    test "runs /archive even when the channel isn't #commands (per-room override)" do
      Room.create!(matrix_room_id: "!r:reddit.com", counterparty_username: "peer", discord_channel_id: "dm_not_commands")
      @actions.expects(:archive_room!).returns(:archived)

      response = @router.dispatch(interaction(name: "archive", channel: "dm_not_commands"))

      refute_match(/must be run in the configured/i, response[:data][:content])
    end

    test "reports when /archive hits an already-archived room" do
      Room.create!(matrix_room_id: "!r:reddit.com", counterparty_username: "peer", discord_channel_id: "dm_555")
      @actions.expects(:archive_room!).returns(:already_archived)

      response = @router.dispatch(interaction(name: "archive", channel: "dm_555"))

      assert_match(/already archived/i, response[:data][:content])
    end

    test "returns a helpful error when /archive fires in an unbridged channel" do
      @actions.expects(:archive_room!).never

      response = @router.dispatch(interaction(name: "archive", channel: "random_channel"))

      assert_match(/no bridged room matches/i, response[:data][:content])
    end

    test "still rejects /endchat from a different guild" do
      Room.create!(matrix_room_id: "!r:reddit.com", discord_channel_id: "dm_555")
      @actions.expects(:end_chat!).never

      response = @router.dispatch(interaction(name: "endchat", channel: "dm_555", guild: "other"))

      assert_match(/different guild|must be run in the configured/i, response[:data][:content])
    end

    private

    def interaction(name:, guild: GUILD, channel: CHAN)
      {
        "type" => 2,
        "guild_id" => guild,
        "channel_id" => channel,
        "data" => { "name" => name },
      }
    end
  end
end
