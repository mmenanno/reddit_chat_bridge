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

      assert_match(/different guild|must be run in the configured/i, embed_description(response))
    end

    test "rejects commands from a different channel when channel is configured" do
      response = @router.dispatch(interaction(name: "ping", channel: "999"))

      assert_match(/must be run in the configured/i, embed_description(response))
    end

    test "runs /ping and replies with pong embed" do
      response = @router.dispatch(interaction(name: "ping"))

      assert_equal(4, response[:type])
      assert_match(/pong/i, embed(response)[:title])
    end

    test "runs /pause by delegating to Admin::Actions" do
      @actions.expects(:pause!).returns(:ok)

      response = @router.dispatch(interaction(name: "pause"))

      assert_match(/paused/i, embed(response)[:title])
      assert_match(%r{/resume}, embed(response)[:description])
    end

    test "runs /resume by delegating to Admin::Actions" do
      @actions.expects(:resume!).returns(:ok)

      response = @router.dispatch(interaction(name: "resume"))

      assert_match(/resumed/i, embed(response)[:title])
    end

    test "/status reports 'paused by operator' when AuthState is operator-paused" do
      AuthState.pause_by_operator!

      response = @router.dispatch(interaction(name: "status"))

      assert_match(/paused by operator/i, embed(response)[:description].to_s)
    end

    test "/status reports 'paused - token rejected' when AuthState was auto-paused" do
      AuthState.mark_failure!("M_UNKNOWN_TOKEN")

      response = @router.dispatch(interaction(name: "status"))

      assert_match(/paused - token rejected/i, embed(response)[:description].to_s)
    end

    test "/status surfaces a description warning when the Reddit cookie is close to expiring" do
      AuthState.current.update!(reddit_session_expires_at: 3.days.from_now)

      response = @router.dispatch(interaction(name: "status"))

      assert_match(/<7 days/, embed(response)[:description].to_s)
    end

    test "runs /reconcile and surfaces the four-way breakdown" do
      @actions.expects(:reconcile_channels!).returns(renamed: 3, unchanged: 5, skipped: 1, errors: 0)

      response = @router.dispatch(interaction(name: "reconcile"))
      pairs = response[:data][:embeds].first[:fields].to_h { |f| [f[:name], f[:value]] }

      assert_equal({ "Renamed" => "3", "Unchanged" => "5", "Skipped" => "1", "Errors" => "0" }, pairs)
    end

    test "catches handler exceptions and surfaces them as ephemeral error embeds" do
      @actions.expects(:pause!).raises(RuntimeError, "db gone")

      response = @router.dispatch(interaction(name: "pause"))

      assert_match(/RuntimeError.*db gone/, embed(response)[:description])
      assert_equal(64, response[:data][:flags])
    end

    test "replies ephemerally so other #commands members don't see responses" do
      response = @router.dispatch(interaction(name: "ping"))

      assert_equal(64, response[:data][:flags])
    end

    test "dispatch is transport-agnostic — same payload works from gateway or HTTP" do
      gateway_response = @router.dispatch(interaction(name: "ping"))
      http_response    = @router.dispatch(interaction(name: "ping"))

      assert_equal(gateway_response, http_response)
    end

    test "removes /resync and /test_discord from the registered command set" do
      names = SlashCommandRouter::COMMAND_DEFINITIONS.map { |c| c[:name] }

      refute_includes(names, "resync")
      refute_includes(names, "test_discord")
    end

    test "an unknown command returns an error embed" do
      response = @router.dispatch(interaction(name: "totally_made_up"))

      assert_match(/Unknown command/i, embed(response)[:description])
    end

    # ---- /endchat (per-room command, runs in the target #dm-* channel) ----

    test "runs /endchat from inside a #dm-* channel and delegates to Admin::Actions" do
      Room.create!(matrix_room_id: "!r:reddit.com", counterparty_username: "testuser", discord_channel_id: "dm_555")
      @actions.expects(:end_chat!).with(matrix_room_id: "!r:reddit.com")

      response = @router.dispatch(interaction(name: "endchat", channel: "dm_555"))

      assert_match(/Ended chat with testuser/, embed(response)[:title])
    end

    test "runs /endchat even when the channel isn't the #commands channel (per-room override)" do
      Room.create!(matrix_room_id: "!r:reddit.com", discord_channel_id: "dm_not_commands")
      @actions.expects(:end_chat!)

      response = @router.dispatch(interaction(name: "endchat", channel: "dm_not_commands"))

      refute_match(/must be run in the configured/i, embed_description(response).to_s)
    end

    test "returns a helpful error when /endchat fires in a channel that isn't linked to a room" do
      @actions.expects(:end_chat!).never

      response = @router.dispatch(interaction(name: "endchat", channel: "some_random_channel"))

      assert_match(/no bridged room matches/i, embed_description(response))
    end

    # ---- /rebuild (global) ----

    test "runs /rebuild globally via Admin::Actions and reports the counts" do
      @actions.expects(:rebuild_all!).returns(rebuilt: 3, rebuild_skipped: 2, rebuild_errors: 1)

      response = @router.dispatch(interaction(name: "rebuild"))

      assert_equal("3", field_value(response, "Refreshed"))
      assert_equal("2", field_value(response, "Skipped (archived/hidden)"))
      assert_equal("1", field_value(response, "Errors"))
    end

    # ---- /refresh (per-room, runs in the target #dm-* channel) ----

    test "runs /refresh from inside a #dm-* channel and delegates to Admin::Actions" do
      Room.create!(matrix_room_id: "!r:reddit.com", counterparty_username: "testuser", discord_channel_id: "dm_555")
      @actions.expects(:refresh_room!).with(matrix_room_id: "!r:reddit.com").returns(renamed: true, posted_attempted: 12)

      response = @router.dispatch(interaction(name: "refresh", channel: "dm_555"))

      assert_match(/Refreshed testuser/, embed(response)[:title])
      assert_equal("renamed", field_value(response, "Channel"))
      assert_equal("12", field_value(response, "Events re-examined"))
    end

    test "reports 'unchanged' when /refresh didn't need to rename" do
      Room.create!(matrix_room_id: "!r:reddit.com", counterparty_username: "peer", discord_channel_id: "dm_555")
      @actions.expects(:refresh_room!).returns(renamed: false, posted_attempted: 0)

      response = @router.dispatch(interaction(name: "refresh", channel: "dm_555"))

      assert_equal("unchanged", field_value(response, "Channel"))
    end

    test "runs /refresh outside #commands (per-room override)" do
      Room.create!(matrix_room_id: "!r:reddit.com", discord_channel_id: "dm_elsewhere")
      @actions.expects(:refresh_room!).returns(renamed: false, posted_attempted: 0)

      response = @router.dispatch(interaction(name: "refresh", channel: "dm_elsewhere"))

      refute_match(/must be run in the configured/i, embed_description(response).to_s)
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

      response = @router.dispatch(interaction(name: "room", channel: "dm_555"))
      pairs = response[:data][:embeds].first[:fields].to_h { |f| [f[:name], f[:value]] }

      assert_match(/testuser/, embed(response)[:title])
      assert_equal(
        {
          "Matrix ID" => "!r:reddit.com",
          "Counterparty" => "@t2_testuser:reddit.com",
          "Discord channel" => "dm_555",
          "Webhook" => "cached",
          "Last event" => "$abc",
          "State" => "linked",
        },
        pairs,
      )
    end

    test "/room labels archived rooms clearly" do
      Room.create!(matrix_room_id: "!r:reddit.com", counterparty_username: "peer", discord_channel_id: "dm_555", archived_at: 1.day.ago)

      response = @router.dispatch(interaction(name: "room", channel: "dm_555"))

      assert_equal("archived", field_value(response, "State"))
    end

    test "/room errors politely when fired in a non-bridged channel" do
      response = @router.dispatch(interaction(name: "room", channel: "some_random_channel"))

      assert_match(/no bridged room matches/i, embed_description(response))
    end

    test "/room renders the counterparty avatar as a thumbnail when cached" do
      Room.create!(
        matrix_room_id: "!r:reddit.com",
        counterparty_username: "peer",
        discord_channel_id: "dm_555",
        counterparty_avatar_url: "https://cdn/snoo.png",
      )

      response = @router.dispatch(interaction(name: "room", channel: "dm_555"))

      assert_equal({ url: "https://cdn/snoo.png" }, embed(response)[:thumbnail])
    end

    # ---- /archive (per-room command, runs in the target #dm-* channel) ----

    test "runs /archive from inside a #dm-* channel and delegates to Admin::Actions" do
      Room.create!(matrix_room_id: "!r:reddit.com", counterparty_username: "testuser", discord_channel_id: "dm_555")
      @actions.expects(:archive_room!).with(matrix_room_id: "!r:reddit.com").returns(:archived)

      response = @router.dispatch(interaction(name: "archive", channel: "dm_555"))

      assert_match(/Archived testuser/, embed(response)[:title])
    end

    test "runs /archive even when the channel isn't #commands (per-room override)" do
      Room.create!(matrix_room_id: "!r:reddit.com", counterparty_username: "peer", discord_channel_id: "dm_not_commands")
      @actions.expects(:archive_room!).returns(:archived)

      response = @router.dispatch(interaction(name: "archive", channel: "dm_not_commands"))

      refute_match(/must be run in the configured/i, embed_description(response).to_s)
    end

    test "reports when /archive hits an already-archived room" do
      Room.create!(matrix_room_id: "!r:reddit.com", counterparty_username: "peer", discord_channel_id: "dm_555")
      @actions.expects(:archive_room!).returns(:already_archived)

      response = @router.dispatch(interaction(name: "archive", channel: "dm_555"))

      assert_match(/already archived/i, embed(response)[:title])
    end

    test "returns a helpful error when /archive fires in an unbridged channel" do
      @actions.expects(:archive_room!).never

      response = @router.dispatch(interaction(name: "archive", channel: "random_channel"))

      assert_match(/no bridged room matches/i, embed_description(response))
    end

    test "still rejects /endchat from a different guild" do
      Room.create!(matrix_room_id: "!r:reddit.com", discord_channel_id: "dm_555")
      @actions.expects(:end_chat!).never

      response = @router.dispatch(interaction(name: "endchat", channel: "dm_555", guild: "other"))

      assert_match(/different guild|must be run in the configured/i, embed_description(response))
    end

    # ---- /unarchive ----

    test "/unarchive errors when no query is given" do
      response = @router.dispatch(interaction(name: "unarchive"))

      assert_match(/Provide a username/, embed_description(response))
    end

    test "/unarchive returns 'no match' when nothing fuzzy-matches" do
      Room.create!(matrix_room_id: "!a:reddit.com", counterparty_username: "alpha", archived_at: 1.day.ago)

      response = @router.dispatch(interaction(name: "unarchive", options: [{ "name" => "query", "value" => "zebra" }]))

      assert_match(/no rooms matched/i, embed_description(response))
    end

    test "/unarchive ignores active (non-archived) rooms when matching" do
      Room.create!(matrix_room_id: "!a:reddit.com", counterparty_username: "alpha") # active

      response = @router.dispatch(interaction(name: "unarchive", options: [{ "name" => "query", "value" => "alpha" }]))

      assert_match(/no rooms matched/i, embed_description(response))
    end

    test "/unarchive shows a confirm row for a single fuzzy match" do
      room = Room.create!(matrix_room_id: "!a:reddit.com", counterparty_username: "alpha", archived_at: 1.day.ago)

      response = @router.dispatch(interaction(name: "unarchive", options: [{ "name" => "query", "value" => "al" }]))

      assert_match(/Confirm.*alpha/i, embed(response)[:title])
      buttons = response[:data][:components].first[:components]

      assert_equal("unarchive:confirm:#{room.id}", buttons.first[:custom_id])
      assert_equal("unarchive:cancel:#{room.id}", buttons.last[:custom_id])
    end

    test "/unarchive shows a select row for multiple fuzzy matches" do
      r1 = Room.create!(matrix_room_id: "!a:reddit.com", counterparty_username: "alpha", archived_at: 1.day.ago)
      r2 = Room.create!(matrix_room_id: "!b:reddit.com", counterparty_username: "alphabet", archived_at: 1.day.ago)

      response = @router.dispatch(interaction(name: "unarchive", options: [{ "name" => "query", "value" => "alph" }]))
      ids = response[:data][:components].first[:components].map { |b| b[:custom_id] }

      assert_equal(
        ["unarchive:select:#{r1.id}", "unarchive:select:#{r2.id}", "unarchive:cancel:0"],
        ids,
      )
    end

    test "/unarchive multi-match embed announces the count" do
      Room.create!(matrix_room_id: "!a:reddit.com", counterparty_username: "alpha", archived_at: 1.day.ago)
      Room.create!(matrix_room_id: "!b:reddit.com", counterparty_username: "alphabet", archived_at: 1.day.ago)

      response = @router.dispatch(interaction(name: "unarchive", options: [{ "name" => "query", "value" => "alph" }]))

      assert_match(/2 matches/i, embed(response)[:title])
    end

    test "/unarchive ranks exact match before substring match" do
      Room.create!(matrix_room_id: "!a:reddit.com", counterparty_username: "alphabet", archived_at: 1.day.ago)
      exact = Room.create!(matrix_room_id: "!b:reddit.com", counterparty_username: "alpha", archived_at: 1.day.ago)

      response = @router.dispatch(interaction(name: "unarchive", options: [{ "name" => "query", "value" => "alpha" }]))

      first_button = response[:data][:components].first[:components].first

      assert_equal("unarchive:select:#{exact.id}", first_button[:custom_id])
    end

    # ---- /restore ----

    test "/restore returns 'no match' when nothing fuzzy-matches" do
      Room.create!(matrix_room_id: "!a:reddit.com", counterparty_username: "alpha", terminated_at: 1.day.ago)

      response = @router.dispatch(interaction(name: "restore", options: [{ "name" => "query", "value" => "zebra" }]))

      assert_match(/no rooms matched/i, embed_description(response))
    end

    test "/restore matches terminated rooms and shows a confirm row" do
      room = Room.create!(matrix_room_id: "!a:reddit.com", counterparty_username: "ghosted", terminated_at: 1.day.ago)

      response = @router.dispatch(interaction(name: "restore", options: [{ "name" => "query", "value" => "ghost" }]))

      assert_match(/Confirm.*ghosted/i, embed(response)[:title])
      buttons = response[:data][:components].first[:components]

      assert_equal("restore:confirm:#{room.id}", buttons.first[:custom_id])
    end

    test "/restore ignores non-terminated rooms when matching" do
      Room.create!(matrix_room_id: "!a:reddit.com", counterparty_username: "ghosted") # active

      response = @router.dispatch(interaction(name: "restore", options: [{ "name" => "query", "value" => "ghost" }]))

      assert_match(/no rooms matched/i, embed_description(response))
    end

    private

    def interaction(name:, guild: GUILD, channel: CHAN, options: nil)
      data = { "name" => name }
      data["options"] = options if options
      {
        "type" => 2,
        "guild_id" => guild,
        "channel_id" => channel,
        "data" => data,
      }
    end

    def embed(response)
      response[:data][:embeds].first
    end

    def embed_description(response)
      embed(response)[:description].to_s
    end

    def field_value(response, name)
      embed(response)[:fields].find { |f| f[:name] == name }&.dig(:value)
    end
  end
end
