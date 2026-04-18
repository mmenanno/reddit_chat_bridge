# frozen_string_literal: true

# Tracks messages the operator typed in Discord that the bridge is
# relaying (or has relayed) to Reddit via Matrix.
#
# Lifecycle:
#   1. Discord gateway sees a MESSAGE_CREATE in a bridged channel. We
#      mint a txn_id and insert a row with status="pending".
#   2. On Matrix.send_message success: update matrix_event_id + status=
#      "sent". The event_id goes into Dedup::SentRegistry so the
#      subsequent /sync echo of this same event doesn't round-trip back
#      into Discord.
#   3. On failure: status="failed" + last_error.
#
# Keeping a table row (instead of just the registry) lets us debug via
# /events and retry a failed send later without losing the source
# Discord message id.
class OutboundMessage < ApplicationRecord
  self.table_name = "outbound_messages"

  STATUS_PENDING = "pending"
  STATUS_SENT    = "sent"
  STATUS_FAILED  = "failed"

  class << self
    def register_sent!(txn_id:, discord_message_id:, matrix_room_id:, matrix_event_id:)
      record = find_or_initialize_by(txn_id: txn_id)
      record.update!(
        discord_message_id: discord_message_id,
        matrix_room_id: matrix_room_id,
        matrix_event_id: matrix_event_id,
        status: STATUS_SENT,
        sent_at: Time.current,
        last_error: nil,
      )
      record
    end

    def register_failure!(txn_id:, discord_message_id:, matrix_room_id:, error:)
      record = find_or_initialize_by(txn_id: txn_id)
      record.update!(
        discord_message_id: discord_message_id,
        matrix_room_id: matrix_room_id,
        status: STATUS_FAILED,
        last_error: error.to_s,
      )
      record
    end

    def posted_event?(matrix_event_id)
      return false if matrix_event_id.to_s.empty?

      exists?(matrix_event_id: matrix_event_id)
    end
  end
end
