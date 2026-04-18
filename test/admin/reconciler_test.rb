# frozen_string_literal: true

require "test_helper"
require "admin/reconciler"
require "matrix/client"

module Admin
  class ReconcilerTest < ActiveSupport::TestCase
    ROOM_ID = "!abc:reddit.com"
    PEER = "@t2_peer:reddit.com"
    CHANNEL_ID = "555555555555555555"

    setup do
      @matrix_client = mock("MatrixClient")
      @discord_client = mock("DiscordClient")
      @channel_index = mock("ChannelIndex")
      @poster = mock("Poster")
      @normalizer = mock("Normalizer")
      @reconciler = Admin::Reconciler.new(
        matrix_client: @matrix_client,
        discord_client: @discord_client,
        channel_index: @channel_index,
        poster: @poster,
        normalizer: @normalizer,
      )
    end

    # ---- reconcile_all ----

    test "renames each room that has a discord channel and counterparty id" do
      room = Room.create!(
        matrix_room_id: ROOM_ID,
        counterparty_matrix_id: PEER,
        counterparty_username: "oldname",
        discord_channel_id: CHANNEL_ID,
      )
      @matrix_client.expects(:profile).with(user_id: PEER).returns("displayname" => "newname")
      @channel_index.expects(:channel_name_for).returns("dm-newname")
      @discord_client.expects(:rename_channel).with(channel_id: CHANNEL_ID, name: "dm-newname")

      stats = @reconciler.reconcile_all

      assert_equal({ renamed: 1, skipped: 0, errors: 0 }, stats)
      assert_equal("newname", room.reload.counterparty_username)
    end

    test "skips rooms without a discord channel id" do
      Room.create!(matrix_room_id: ROOM_ID, counterparty_matrix_id: PEER, discord_channel_id: nil)

      stats = @reconciler.reconcile_all

      assert_equal({ renamed: 0, skipped: 0, errors: 0 }, stats)
    end

    test "skips rooms without a counterparty matrix id" do
      Room.create!(matrix_room_id: ROOM_ID, counterparty_matrix_id: nil, discord_channel_id: CHANNEL_ID)

      stats = @reconciler.reconcile_all

      assert_equal({ renamed: 0, skipped: 1, errors: 0 }, stats)
    end

    test "counts per-room failures under errors without aborting the sweep" do
      Room.create!(matrix_room_id: ROOM_ID, counterparty_matrix_id: PEER, discord_channel_id: CHANNEL_ID)
      other_room_id = "!xyz:reddit.com"
      other_peer = "@t2_other:reddit.com"
      Room.create!(matrix_room_id: other_room_id, counterparty_matrix_id: other_peer, discord_channel_id: "666")

      @matrix_client.expects(:profile).with(user_id: PEER).raises(Matrix::Error, "boom")
      @matrix_client.expects(:profile).with(user_id: other_peer).returns("displayname" => "good")
      @channel_index.expects(:channel_name_for).at_least_once.returns("dm-good")
      @discord_client.expects(:rename_channel).with(channel_id: "666", name: "dm-good")

      stats = @reconciler.reconcile_all

      assert_equal({ renamed: 1, skipped: 0, errors: 1 }, stats)
    end

    test "renames even when profile returns nil, using the existing username" do
      Room.create!(
        matrix_room_id: ROOM_ID,
        counterparty_matrix_id: PEER,
        counterparty_username: "existing",
        discord_channel_id: CHANNEL_ID,
      )
      @matrix_client.expects(:profile).with(user_id: PEER).returns(nil)
      @channel_index.expects(:channel_name_for).returns("dm-existing")
      @discord_client.expects(:rename_channel).with(channel_id: CHANNEL_ID, name: "dm-existing")

      stats = @reconciler.reconcile_all

      assert_equal(1, stats[:renamed])
    end

    # ---- refresh_one ----

    test "refresh_one renames and backfills events in chronological order" do
      Room.create!(
        matrix_room_id: ROOM_ID,
        counterparty_matrix_id: PEER,
        counterparty_username: "nothnnn",
        discord_channel_id: CHANNEL_ID,
      )
      @matrix_client.expects(:profile).with(user_id: PEER).returns("displayname" => "nothnnn")
      @channel_index.expects(:channel_name_for).returns("dm-nothnnn")
      @discord_client.expects(:rename_channel).with(channel_id: CHANNEL_ID, name: "dm-nothnnn")

      messages_body = {
        "chunk" => [
          { "type" => "m.room.message", "event_id" => "$2" },
          { "type" => "m.room.message", "event_id" => "$1" },
        ],
        "state" => [],
      }
      @matrix_client.expects(:room_messages)
        .with(room_id: ROOM_ID, dir: "b", limit: Admin::Reconciler::DEFAULT_HISTORY_LIMIT)
        .returns(messages_body)

      newest_first = [stub(event_id: "$2"), stub(event_id: "$1")]
      @normalizer.expects(:normalize).returns(newest_first)
      @poster.expects(:call).with { |events| events.map(&:event_id) == ["$1", "$2"] }

      result = @reconciler.refresh_one(matrix_room_id: ROOM_ID)

      assert_equal({ renamed: true, posted_attempted: 2 }, result)
    end

    test "refresh_one raises when the room is unknown" do
      assert_raises(ArgumentError) { @reconciler.refresh_one(matrix_room_id: "!nope:reddit.com") }
    end

    # ---- deleted-channel recovery ----

    test "reconcile_all recreates the channel when Discord returns 404 on rename" do
      Room.create!(
        matrix_room_id: ROOM_ID,
        counterparty_matrix_id: PEER,
        counterparty_username: "nothnnn",
        discord_channel_id: CHANNEL_ID,
      )
      @matrix_client.expects(:profile).returns("displayname" => "nothnnn")
      @channel_index.expects(:channel_name_for).at_least_once.returns("dm-nothnnn")
      @discord_client.expects(:rename_channel)
        .with(channel_id: CHANNEL_ID, name: "dm-nothnnn")
        .raises(Discord::NotFound, "Unknown Channel")
      @channel_index.expects(:ensure_channel).with { |args| args[:room].discord_channel_id.nil? }.returns("999")

      stats = @reconciler.reconcile_all

      assert_equal(1, stats[:renamed])
      assert_equal(0, stats[:errors])
    end

    test "refresh_one creates a fresh channel when the room has none (post-unarchive case)" do
      room = Room.create!(matrix_room_id: ROOM_ID, counterparty_matrix_id: PEER, counterparty_username: "nothnnn")
      # Simulate the real ChannelIndex by attaching on the passed Room instance;
      # otherwise reconcile_room skips (no channel) and the rename path doesn't fire.
      @channel_index.expects(:ensure_channel).with do |args|
        args[:room].attach_discord_channel!("new_chan")
        true
      end.returns("new_chan")
      @matrix_client.expects(:profile).returns("displayname" => "nothnnn")
      @channel_index.expects(:channel_name_for).at_least_once.returns("dm-nothnnn")
      @discord_client.expects(:rename_channel).at_least_once
      @matrix_client.expects(:room_messages).returns("chunk" => [], "state" => [])
      @normalizer.expects(:normalize).returns([])
      @poster.expects(:call)

      @reconciler.refresh_one(matrix_room_id: ROOM_ID)

      assert_equal("new_chan", room.reload.discord_channel_id)
    end

    test "refresh_one recreates the channel before backfilling when the old one is gone" do
      Room.create!(
        matrix_room_id: ROOM_ID,
        counterparty_matrix_id: PEER,
        counterparty_username: "nothnnn",
        discord_channel_id: CHANNEL_ID,
      )
      @matrix_client.expects(:profile).returns("displayname" => "nothnnn")
      @channel_index.expects(:channel_name_for).at_least_once.returns("dm-nothnnn")
      @discord_client.expects(:rename_channel).raises(Discord::NotFound, "Unknown Channel")
      @channel_index.expects(:ensure_channel).returns("999")
      @matrix_client.expects(:room_messages).returns("chunk" => [], "state" => [])
      @normalizer.expects(:normalize).returns([])
      @poster.expects(:call)

      result = @reconciler.refresh_one(matrix_room_id: ROOM_ID)

      assert(result[:renamed])
    end

    # ---- delete_all_discord_channels! ----

    test "delete_all_discord_channels! deletes every room's Discord channel" do
      Room.create!(matrix_room_id: "!a:reddit.com", discord_channel_id: "111")
      Room.create!(matrix_room_id: "!b:reddit.com", discord_channel_id: "222")
      Room.create!(matrix_room_id: "!c:reddit.com", discord_channel_id: nil) # skipped
      @discord_client.expects(:delete_channel).with(channel_id: "111").returns(:ok)
      @discord_client.expects(:delete_channel).with(channel_id: "222").returns(:ok)

      assert_equal(
        { channels_deleted: 2, channel_delete_errors: 0 },
        @reconciler.delete_all_discord_channels!,
      )
    end

    test "delete_all_discord_channels! counts NotFound as successful deletion" do
      Room.create!(matrix_room_id: "!a:reddit.com", discord_channel_id: "111")
      @discord_client.expects(:delete_channel).raises(Discord::NotFound, "Unknown Channel")

      stats = @reconciler.delete_all_discord_channels!

      assert_equal(1, stats[:channels_deleted])
      assert_equal(0, stats[:channel_delete_errors])
    end

    test "delete_all_discord_channels! counts other failures and keeps going" do
      Room.create!(matrix_room_id: "!a:reddit.com", discord_channel_id: "111")
      Room.create!(matrix_room_id: "!b:reddit.com", discord_channel_id: "222")
      @discord_client.expects(:delete_channel)
        .with(channel_id: "111").raises(Discord::AuthError, "Missing Permissions")
      @discord_client.expects(:delete_channel)
        .with(channel_id: "222").returns(:ok)

      stats = @reconciler.delete_all_discord_channels!

      assert_equal(1, stats[:channels_deleted])
      assert_equal(1, stats[:channel_delete_errors])
    end

    # ---- archive / unarchive ----

    test "archive! deletes the Discord channel and flags the room archived" do
      room = Room.create!(
        matrix_room_id: ROOM_ID,
        discord_channel_id: CHANNEL_ID,
        discord_webhook_id: "wh",
        discord_webhook_token: "tok",
      )
      @discord_client.expects(:delete_channel).with(channel_id: CHANNEL_ID).returns(:ok)

      assert_equal(:archived, @reconciler.archive!(matrix_room_id: ROOM_ID))

      refute_predicate(room.reload, :discord_channel_id)
      assert_predicate(room, :archived?)
    end

    test "archive! tolerates a channel that Discord already forgot" do
      Room.create!(matrix_room_id: ROOM_ID, discord_channel_id: CHANNEL_ID)
      @discord_client.expects(:delete_channel).raises(Discord::NotFound, "Unknown Channel")

      assert_equal(:archived, @reconciler.archive!(matrix_room_id: ROOM_ID))
    end

    test "archive! short-circuits when the room is already archived" do
      Room.create!(matrix_room_id: ROOM_ID, archived_at: 1.day.ago)
      @discord_client.expects(:delete_channel).never

      assert_equal(:already_archived, @reconciler.archive!(matrix_room_id: ROOM_ID))
    end

    test "unarchive! flips the flag and recreates the channel without pulling history by default" do
      room = Room.create!(matrix_room_id: ROOM_ID, archived_at: 1.day.ago)
      @channel_index.expects(:ensure_channel).with { |args| args[:room].matrix_room_id == ROOM_ID }.returns("new_chan")
      @matrix_client.expects(:room_messages).never
      @poster.expects(:call).never

      result = @reconciler.unarchive!(matrix_room_id: ROOM_ID)

      refute_predicate(room.reload, :archived?)
      assert_equal({ posted_attempted: 0 }, result)
    end

    test "unarchive! with backfill:true recreates the channel AND pulls recent messages through the poster" do
      Room.create!(matrix_room_id: ROOM_ID, archived_at: 1.day.ago)
      @channel_index.expects(:ensure_channel).returns("new_chan")
      @matrix_client.expects(:room_messages)
        .with(room_id: ROOM_ID, dir: "b", limit: 50)
        .returns("chunk" => [{ "type" => "m.room.message", "event_id" => "$e" }], "state" => [])
      @normalizer.expects(:normalize).returns([:fake_event])
      @poster.expects(:call).with([:fake_event])

      result = @reconciler.unarchive!(matrix_room_id: ROOM_ID, backfill: true)

      assert_equal(1, result[:posted_attempted])
    end
  end
end
