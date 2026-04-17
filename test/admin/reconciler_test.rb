# frozen_string_literal: true

require "test_helper"
require "admin/reconciler"

module Admin
  class ReconcilerTest < ActiveSupport::TestCase
    ROOM_ID = "!abc:reddit.com"
    PEER = "@t2_peer:reddit.com"
    CHANNEL_ID = "555555555555555555"

    def setup
      super
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

      @matrix_client.stubs(:profile).with(user_id: PEER).raises(Matrix::Error, "boom")
      @matrix_client.stubs(:profile).with(user_id: other_peer).returns("displayname" => "good")
      @channel_index.stubs(:channel_name_for).returns("dm-good")
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
  end
end
