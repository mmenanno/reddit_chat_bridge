# frozen_string_literal: true

# Singleton row that tracks where the Matrix /sync long-poll left off.
#
# Advanced *only* after a batch of events has been dispatched successfully,
# so a crash between receive and dispatch results in a replay on restart
# (the `Dedup::SentRegistry` handles the Phase 2 echo case; this class
# guarantees we never lose a message by advancing prematurely).
class SyncCheckpoint < ApplicationRecord
  self.table_name = "sync_checkpoints"

  class << self
    def current
      first || create!
    end

    def next_batch_token
      current.next_batch_token
    end

    def advance!(token)
      current.update!(next_batch_token: token, last_batch_at: Time.current)
    end

    def reset!
      current.update!(next_batch_token: nil, last_batch_at: nil)
    end
  end
end
