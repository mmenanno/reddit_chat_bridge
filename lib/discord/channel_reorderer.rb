# frozen_string_literal: true

module Discord
  # Keeps `#dm-*` channels sorted most-recent-first by pushing positions
  # to Discord's bulk reorder endpoint. The Poster and OutboundDispatcher
  # call `reorder!` at the tail of a successful post/dispatch, so the
  # order updates the moment a new message lands (one API call per sync
  # batch, not per event).
  #
  # Safe to call even when nothing has changed — Discord treats repeated
  # identical positions as a no-op, so there's no idempotency bookkeeping
  # on our side. Failures are logged and swallowed; a stale order is
  # cosmetic, not a bridge correctness issue.
  class ChannelReorderer
    def initialize(client:, guild_id:, logger: nil)
      @client = client
      @guild_id = guild_id.to_s
      @logger = logger
    end

    def reorder!
      return if @guild_id.empty?

      positions = desired_positions
      return if positions.empty?

      @client.reorder_channels(guild_id: @guild_id, positions: positions)
    rescue Discord::Error => e
      @logger&.warn("channel reorder failed: #{e.class}: #{e.message}")
    end

    private

    # All active bridged rooms (not archived, not terminated, channel
    # exists) ordered by last_activity_at desc — rooms with no activity
    # timestamp sort to the bottom. Secondary order on id keeps the
    # result deterministic when two rooms share a timestamp. Uses a
    # CASE sentinel instead of `NULLS LAST` so the query works on older
    # SQLite builds and any other backend the plan swaps in.
    def desired_positions
      null_last = Arel.sql("CASE WHEN last_activity_at IS NULL THEN 1 ELSE 0 END")
      Room.where.not(discord_channel_id: nil)
        .where(archived_at: nil, terminated_at: nil)
        .order(null_last, last_activity_at: :desc, id: :asc)
        .each_with_index
        .map { |room, i| { id: room.discord_channel_id, position: i } }
    end
  end
end
