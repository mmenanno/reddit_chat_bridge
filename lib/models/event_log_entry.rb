# frozen_string_literal: true

# Persisted operational log. Every important thing the bridge does
# (auth refresh failures, token rotations, Discord rate limits, channel
# recreations, etc.) gets a row here so the /events page can render a
# tail without relying on Discord's #app-logs channel being scrolled.
#
# Ring-buffer semantics: we prune to MAX_ROWS every write so the table
# stays bounded. At N=250 rows the tail covers a routine debugging
# session without letting the log grow unbounded.
class EventLogEntry < ApplicationRecord
  self.table_name = "event_log_entries"

  LEVELS = ["info", "warn", "error", "critical"].freeze
  MAX_ROWS = 250

  validates(:level, inclusion: { in: LEVELS })
  validates(:message, presence: true)

  class << self
    def record!(level:, message:, source: nil, context: nil)
      entry = create!(
        level: level.to_s,
        source: source&.to_s,
        message: message.to_s,
        context: serialize_context(context),
        created_at: Time.current,
      )
      trim!
      entry
    rescue ActiveRecord::RecordInvalid
      # Journal writes must never crash the caller. Swallow a bad entry
      # and move on; the caller's own retries already cover reliability.
      nil
    end

    def recent(limit: 500)
      order(created_at: :desc).limit(limit)
    end

    def page_of(page:, per_page:)
      order(created_at: :desc).limit(per_page).offset((page - 1) * per_page)
    end

    def trim!
      return if count <= MAX_ROWS

      cutoff = order(created_at: :desc).offset(MAX_ROWS - 1).pick(:created_at)
      return unless cutoff

      where(arel_table[:created_at].lt(cutoff)).delete_all
    end

    # Full wipe for the /events "Clear log" button. Returns the row count
    # that was deleted so the UI can surface a concrete confirmation.
    def clear_all!
      delete_all
    end

    private

    def serialize_context(context)
      return if context.nil?
      return context if context.is_a?(String)

      JSON.generate(context)
    end
  end

  def context_hash
    return {} if context.to_s.empty?

    JSON.parse(context)
  rescue JSON::ParserError
    {}
  end
end
