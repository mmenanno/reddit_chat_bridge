# frozen_string_literal: true

require "test_helper"
require "bridge/application"
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

    test "runs /pause by delegating to Admin::Actions" do
      @actions.expects(:pause!).returns(:ok)

      response = @router.dispatch(interaction(name: "pause"))

      assert_match(/paused/i, response[:data][:content])
      assert_match(%r{/resume}, response[:data][:content])
    end

    test "runs /resume by delegating to Admin::Actions" do
      @actions.expects(:resume!).returns(:ok)

      response = @router.dispatch(interaction(name: "resume"))

      assert_match(/resumed/i, response[:data][:content])
    end

    test "/status reports 'paused by operator' when AuthState is operator-paused" do
      AuthState.pause_by_operator!

      response = @router.dispatch(interaction(name: "status"))

      assert_match(/paused by operator/i, response[:data][:content])
    end

    test "/status reports 'paused — token rejected' when AuthState was auto-paused" do
      AuthState.mark_failure!("M_UNKNOWN_TOKEN")

      response = @router.dispatch(interaction(name: "status"))

      assert_match(/paused — token rejected/i, response[:data][:content])
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

    # ---- /test_discord (global) ----

    test "runs /test_discord via Admin::Actions and reports success" do
      @actions.expects(:test_discord!).returns(channel_id: "555", message_id: "m")

      response = @router.dispatch(interaction(name: "test_discord"))

      assert_match(/Probe posted/, response[:data][:content])
    end

    # ---- /rebuild (global) ----

    test "runs /rebuild globally via Admin::Actions and reports the counts" do
      @actions.expects(:rebuild_all!).returns(rebuilt: 3, rebuild_errors: 1)

      response = @router.dispatch(interaction(name: "rebuild"))

      assert_match(/3 room\(s\) refreshed.*1 errors/, response[:data][:content])
    end

    # ---- /refresh (per-room, runs in the target #dm-* channel) ----

    test "runs /refresh from inside a #dm-* channel and delegates to Admin::Actions" do
      Room.create!(matrix_room_id: "!r:reddit.com", counterparty_username: "testuser", discord_channel_id: "dm_555")
      @actions.expects(:refresh_room!).with(matrix_room_id: "!r:reddit.com").returns(renamed: true, posted_attempted: 12)

      response = @router.dispatch(interaction(name: "refresh", channel: "dm_555"))

      assert_match(/Refreshed \*\*testuser\*\*.*channel renamed.*12 event/, response[:data][:content])
    end

    test "reports 'unchanged' when /refresh didn't need to rename" do
      Room.create!(matrix_room_id: "!r:reddit.com", counterparty_username: "peer", discord_channel_id: "dm_555")
      @actions.expects(:refresh_room!).returns(renamed: false, posted_attempted: 0)

      response = @router.dispatch(interaction(name: "refresh", channel: "dm_555"))

      assert_match(/channel unchanged/, response[:data][:content])
    end

    test "runs /refresh outside #commands (per-room override)" do
      Room.create!(matrix_room_id: "!r:reddit.com", discord_channel_id: "dm_elsewhere")
      @actions.expects(:refresh_room!).returns(renamed: false, posted_attempted: 0)

      response = @router.dispatch(interaction(name: "refresh", channel: "dm_elsewhere"))

      refute_match(/must be run in the configured/i, response[:data][:content])
    end

    # ---- /room (per-room diagnostic) ----

    test "/room dumps current room details for the channel it was invoked in" do
      Room.create!(
        matrix_room_id: "!r:reddit.com",
        counterparty_username: "testuser",
        counterparty_matrix_id: "@t2_testuser:reddit.com",
        discord_channel_id: "dm_555",
        discord_webhook_id: "wh_1",
        discord_webhook_token: "tok_1",
        last_event_id: "$abc",
      )

      body = @router.dispatch(interaction(name: "room", channel: "dm_555"))[:data][:content]

      assert_match(/testuser.*!r:reddit\.com.*@t2_testuser:reddit\.com.*cached.*State:\s*linked/m, body)
    end

    test "/room labels archived rooms clearly" do
      Room.create!(matrix_room_id: "!r:reddit.com", counterparty_username: "peer", discord_channel_id: "dm_555", archived_at: 1.day.ago)

      response = @router.dispatch(interaction(name: "room", channel: "dm_555"))

      assert_match(/State:\s*archived/, response[:data][:content])
    end

    test "/room errors politely when fired in a non-bridged channel" do
      response = @router.dispatch(interaction(name: "room", channel: "some_random_channel"))

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
