# frozen_string_literal: true

# Durable record of Matrix event_ids we've already delivered to Discord.
# The Poster checks this before each send and inserts on success so that a
# checkpoint rewind (after a mid-batch failure) doesn't cause previously-
# posted events to go out a second time.
#
# Indexed by event_id (unique) for O(log n) existence checks. Old rows
# are pruned by AuthState / a maintenance task — kept as far back as the
# longest plausible /sync lag to cover crash-resume scenarios.
class PostedEvent < ApplicationRecord
  self.table_name = "posted_events"

  RETENTION_WINDOW = 30.days

  class << self
    def posted?(event_id)
      exists?(event_id: event_id)
    end

    def record!(event_id:, room_id:)
      create!(event_id: event_id, room_id: room_id, posted_at: Time.current)
    rescue ActiveRecord::RecordNotUnique
      # Concurrent retry beat us to it — that's fine, the invariant holds.
      nil
    end

    def prune!(older_than: RETENTION_WINDOW)
      where(arel_table[:posted_at].lt(Time.current - older_than)).delete_all
    end
  end
end
