# frozen_string_literal: true

require "discord/client"

module Admin
  # One-shot reconciliation for rooms whose Discord channel drifted out of
  # sync with the counterparty's Reddit username — usually because the
  # username resolved after the initial `dm-t2_<id>` channel was created,
  # and the Poster's live rename path didn't fire (e.g. every subsequent
  # event was already in `PostedEvent`, so `post_one` short-circuited).
  #
  # Two operations:
  #   - `reconcile_all` — sweep every Room with a Discord channel, fetch
  #     its counterparty's Matrix profile, update the stored username,
  #     and rename the channel to the current slug. Rename is idempotent
  #     on Discord's side; calling it unconditionally avoids needing a
  #     "last known Discord name" cache.
  #   - `refresh_one` — same reconcile for a single room, plus a backfill
  #     of recent history via Matrix `/messages?dir=b`. Events that were
  #     already posted are skipped by the Poster's `PostedEvent.posted?`
  #     check, so replay is safe.
  class Reconciler
    DEFAULT_HISTORY_LIMIT = 50

    # Dependency-injection boundary — all collaborators are required for
    # the reconcile/backfill flow to work. Disabling ParameterLists here is
    # the common Ruby escape hatch for service objects with >5 collaborators.
    def initialize(matrix_client:, discord_client:, channel_index:, poster:, normalizer:, logger: nil) # rubocop:disable Metrics/ParameterLists
      @matrix_client = matrix_client
      @discord_client = discord_client
      @channel_index = channel_index
      @poster = poster
      @normalizer = normalizer
      @logger = logger
    end

    def reconcile_all
      stats = { renamed: 0, skipped: 0, errors: 0 }
      Room.where.not(discord_channel_id: nil).find_each do |room|
        stats[reconcile_room(room)] += 1
      rescue StandardError => e
        stats[:errors] += 1
        @logger&.warn("reconcile failed for #{room.matrix_room_id}: #{e.class}: #{e.message}")
      end
      stats
    end

    def refresh_one(matrix_room_id:, history_limit: DEFAULT_HISTORY_LIMIT)
      room = Room.find_by(matrix_room_id: matrix_room_id)
      raise(ArgumentError, "no such room: #{matrix_room_id}") unless room

      renamed = reconcile_room(room) == :renamed
      posted = backfill_history(room, limit: history_limit)
      { renamed: renamed, posted_attempted: posted }
    end

    # Bulk-delete every Discord channel we currently track. Used by
    # `full_resync!` so the operator can click one button to rebuild from
    # scratch, including wiping stale Discord state — not just the DB side.
    # NotFound counts as success (channel was already gone).
    def delete_all_discord_channels!
      stats = { channels_deleted: 0, channel_delete_errors: 0 }
      Room.where.not(discord_channel_id: nil).find_each do |room|
        @discord_client.delete_channel(channel_id: room.discord_channel_id)
        stats[:channels_deleted] += 1
      rescue Discord::NotFound
        stats[:channels_deleted] += 1
      rescue StandardError => e
        stats[:channel_delete_errors] += 1
        @logger&.warn("channel delete failed for #{room.matrix_room_id}: #{e.class}: #{e.message}")
      end
      stats
    end

    # Archive: delete the Discord channel (if any) and mark the room archived.
    # Room metadata is kept so the slug survives for the eventual unarchive.
    # NotFound on delete is benign — the channel was already gone on Discord's
    # side, so the local archive flag is the only thing left to flip.
    def archive!(matrix_room_id:)
      room = Room.find_by(matrix_room_id: matrix_room_id)
      raise(ArgumentError, "no such room: #{matrix_room_id}") unless room
      return :already_archived if room.archived?

      delete_discord_channel!(room)
      room.archive!
      :archived
    end

    # Unarchive with an optional full-history backfill. Without backfill,
    # the room is just un-flagged — the next inbound message creates a
    # fresh channel via the normal Poster path.
    def unarchive!(matrix_room_id:, backfill: false, history_limit: DEFAULT_HISTORY_LIMIT)
      room = Room.find_by(matrix_room_id: matrix_room_id)
      raise(ArgumentError, "no such room: #{matrix_room_id}") unless room

      room.unarchive!
      posted = backfill ? backfill_history(room, limit: history_limit) : 0
      { posted_attempted: posted }
    end

    private

    # Returns :renamed or :skipped — the tally keys used by `reconcile_all`.
    def reconcile_room(room)
      return :skipped unless room.counterparty_matrix_id
      return :skipped unless room.discord_channel_id

      username = fetch_profile_username(room.counterparty_matrix_id)
      room.ensure_counterparty!(matrix_id: room.counterparty_matrix_id, username: username)

      new_slug = @channel_index.channel_name_for(room.reload)
      rename_or_recreate!(room, new_slug)
      :renamed
    end

    # Discord returns 404 on rename when the channel has been deleted by the
    # operator. Clear the stale id and let ChannelIndex create a fresh one
    # — name is already current so no follow-up rename is needed.
    def rename_or_recreate!(room, new_slug)
      @discord_client.rename_channel(channel_id: room.discord_channel_id, name: new_slug)
    rescue Discord::NotFound
      room.update!(discord_channel_id: nil)
      @channel_index.ensure_channel(room: room)
    end

    def delete_discord_channel!(room)
      return unless room.discord_channel_id

      @discord_client.delete_channel(channel_id: room.discord_channel_id)
    rescue Discord::NotFound
      # Already gone on Discord's side; nothing to undo.
      nil
    end

    def fetch_profile_username(matrix_id)
      profile = @matrix_client.profile(user_id: matrix_id)
      profile.is_a?(Hash) ? profile["displayname"] : nil
    end

    def backfill_history(room, limit:)
      response = @matrix_client.room_messages(room_id: room.matrix_room_id, dir: "b", limit: limit)
      sync_shaped = wrap_as_sync(response, room_id: room.matrix_room_id)
      events = @normalizer.normalize(sync_shaped)
      # `/messages?dir=b` returns newest first; post in chronological order.
      @poster.call(events.reverse)
      events.size
    end

    def wrap_as_sync(messages_body, room_id:)
      {
        "rooms" => {
          "join" => {
            room_id => {
              "timeline" => { "events" => messages_body["chunk"] || [] },
              "state" => { "events" => messages_body["state"] || [] },
            },
          },
        },
      }
    end
  end
end
