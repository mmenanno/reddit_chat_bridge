# frozen_string_literal: true

require "concurrent"
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
    # 4 workers keeps us well under Discord's 50 req/s global limit even
    # when every room triggers a profile fetch + rename (~2 requests) and
    # leaves headroom for the Poster posting on the side.
    DEFAULT_PARALLELISM = 4

    # Dependency-injection boundary — all collaborators are required for
    # the reconcile/backfill flow to work. Disabling ParameterLists here is
    # the common Ruby escape hatch for service objects with >5 collaborators.
    def initialize(matrix_client:, discord_client:, channel_index:, poster:, normalizer:, logger: nil, parallelism: DEFAULT_PARALLELISM)
      @matrix_client = matrix_client
      @discord_client = discord_client
      @channel_index = channel_index
      @poster = poster
      @normalizer = normalizer
      @logger = logger
      @parallelism = parallelism
    end

    def reconcile_all
      renamed = Concurrent::AtomicFixnum.new
      unchanged = Concurrent::AtomicFixnum.new
      skipped = Concurrent::AtomicFixnum.new
      errors = Concurrent::AtomicFixnum.new
      each_in_parallel(Room.where.not(discord_channel_id: nil)) do |room|
        case reconcile_room(room)
        when :renamed then renamed.increment
        when :unchanged then unchanged.increment
        when :skipped then skipped.increment
        end
      rescue StandardError => e
        errors.increment
        @logger&.warn("reconcile failed for #{room.matrix_room_id}: #{e.class}: #{e.message}")
      end
      { renamed: renamed.value, unchanged: unchanged.value, skipped: skipped.value, errors: errors.value }
    end

    def refresh_one(matrix_room_id:, history_limit: DEFAULT_HISTORY_LIMIT)
      room = Room.find_by(matrix_room_id: matrix_room_id)
      raise(ArgumentError, "no such room: #{matrix_room_id}") unless room

      # A "pending" (no channel) room needs a channel before rename/backfill
      # can do useful work — otherwise reconcile_room skips silently and
      # backfill only creates a channel if there's at least one event to
      # post, which means quiet conversations stay broken after an unarchive.
      @channel_index.ensure_channel(room: room) if room.discord_channel_id.nil? && !room.archived?

      renamed = reconcile_room(room.reload) == :renamed
      posted = backfill_history(room.reload, limit: history_limit)
      { renamed: renamed, posted_attempted: posted }
    end

    # Bulk-delete every Discord channel we currently track. Used by
    # `full_resync!` so the operator can click one button to rebuild from
    # scratch, including wiping stale Discord state — not just the DB side.
    # NotFound counts as success (channel was already gone).
    def delete_all_discord_channels!
      deleted = Concurrent::AtomicFixnum.new
      failed = Concurrent::AtomicFixnum.new
      each_in_parallel(Room.where.not(discord_channel_id: nil)) do |room|
        @discord_client.delete_channel(channel_id: room.discord_channel_id)
        deleted.increment
      rescue Discord::NotFound
        deleted.increment
      rescue StandardError => e
        failed.increment
        @logger&.warn("channel delete failed for #{room.matrix_room_id}: #{e.class}: #{e.message}")
      end
      { channels_deleted: deleted.value, channel_delete_errors: failed.value }
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

    # Hide the chat locally. Reddit's Matrix server refuses Matrix
    # /leave on DM rooms (their own UI only offers a "Hide chat"
    # button, no delete/leave), so for DMs we skip the Matrix call
    # entirely and go straight to local termination: delete the
    # Discord channel, clear dedup + message-request records, flip
    # the Room's terminated_at flag. The Poster and InviteHandler
    # filter events from terminated rooms so nothing gets re-bridged
    # unless the operator explicitly restores. Non-DM rooms (future
    # edge cases — group chats, etc.) still attempt /leave.
    def end_chat!(matrix_room_id:)
      room = Room.find_by(matrix_room_id: matrix_room_id)
      raise(ArgumentError, "no such room: #{matrix_room_id}") unless room

      try_leave_matrix!(room) unless room.is_direct?
      delete_discord_channel!(room) if room.discord_channel_id

      ActiveRecord::Base.transaction do
        MessageRequest.where(matrix_room_id: room.matrix_room_id).delete_all
        room.terminate_locally!
      end
      :ended
    end

    def restore_chat!(matrix_room_id:)
      room = Room.find_by(matrix_room_id: matrix_room_id)
      raise(ArgumentError, "no such room: #{matrix_room_id}") unless room

      room.restore!
      :restored
    end

    # Unarchive: flip the flag and immediately recreate the Discord channel
    # so the room goes back to "linked" state without waiting for a new
    # message. Backfill is optional — with it, recent history is replayed
    # into the fresh channel via the Poster; without it, the channel comes
    # up empty and fills in as new messages arrive.
    def unarchive!(matrix_room_id:, backfill: false, history_limit: DEFAULT_HISTORY_LIMIT)
      room = Room.find_by(matrix_room_id: matrix_room_id)
      raise(ArgumentError, "no such room: #{matrix_room_id}") unless room

      room.unarchive!
      @channel_index.ensure_channel(room: room.reload)
      posted = backfill ? backfill_history(room.reload, limit: history_limit) : 0
      { posted_attempted: posted }
    end

    private

    # Iterate a scope, running the block for each record. When `@parallelism`
    # is >1 the block is dispatched through a fixed thread pool so each worker
    # can make its (slow) Discord/Matrix HTTP call while others are in flight.
    # Each worker checks out its own AR connection for the duration of the
    # block so concurrent queries don't collide on a single checkout.
    def each_in_parallel(scope, &)
      return scope.find_each(&) if @parallelism <= 1

      pool = Concurrent::FixedThreadPool.new(@parallelism)
      scope.find_each do |record|
        pool.post do
          ActiveRecord::Base.connection_pool.with_connection { yield record }
        end
      end
      pool.shutdown
      pool.wait_for_termination
    end

    # Returns :renamed, :unchanged, or :skipped — the tally keys used by
    # `reconcile_all`. :unchanged is the no-op outcome where Discord already
    # has the right name + topic; surfacing it separately stops the slash
    # command from claiming "3 renamed" when nothing actually moved.
    def reconcile_room(room)
      return :skipped unless room.counterparty_matrix_id
      return :skipped unless room.discord_channel_id

      username = fetch_profile_username(room.counterparty_matrix_id)
      room.ensure_counterparty!(matrix_id: room.counterparty_matrix_id, username: username)

      fresh = room.reload
      new_slug = @channel_index.channel_name_for(fresh)
      new_topic = @channel_index.topic_for(fresh)
      rename_or_recreate!(fresh, new_slug, new_topic)
    end

    # Discord returns 404 on rename when the channel has been deleted by the
    # operator. Clear the stale id, forget the dedup cache for this room
    # (old posted-events pointed at a channel that no longer exists —
    # keeping them makes backfills skip every event), then let ChannelIndex
    # create a fresh channel. Name + topic are both included so the topic
    # links stay fresh without a follow-up PATCH.
    #
    # Returns :renamed when an update fired (or a recreate happened), or
    # :unchanged when Discord already had the desired name + topic.
    def rename_or_recreate!(room, new_slug, new_topic)
      return :unchanged if channel_already_matches?(room.discord_channel_id, name: new_slug, topic: new_topic)

      @discord_client.update_channel(channel_id: room.discord_channel_id, name: new_slug, topic: new_topic)
      :renamed
    rescue Discord::NotFound
      room.update!(discord_channel_id: nil)
      room.forget_posted_events!
      @channel_index.ensure_channel(room: room)
      :renamed
    end

    # Best-effort comparison between Discord's current channel state and
    # the slug/topic the reconciler wants to apply. Any failure to fetch
    # falls through to the update path — the rename is idempotent on
    # Discord's side, so over-attempting is safe; under-counting was the
    # bug we're fixing.
    def channel_already_matches?(channel_id, name:, topic:)
      current = @discord_client.get_channel(channel_id)
      current["name"] == name && current["topic"].to_s == topic.to_s
    rescue Discord::Error
      false
    end

    # Only invoked for non-DM rooms now — end_chat! short-circuits the
    # call for is_direct? rooms since Reddit's Matrix server always
    # returns M_FORBIDDEN on /leave for DMs. Kept as a best-effort
    # path for any future non-DM room type.
    def try_leave_matrix!(room)
      @matrix_client.leave_room(room_id: room.matrix_room_id)
    rescue Matrix::Error => e
      @logger&.warn(
        "Matrix /leave refused for #{room.matrix_room_id} (#{e.message}); terminating locally only.",
      )
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
