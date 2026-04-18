# frozen_string_literal: true

# One row per Reddit chat room the bridge has seen. Caches the mapping the
# Discord side needs — Matrix room → Discord channel, plus the
# counterparty's `t2_` id and resolved Reddit username (the username is
# what becomes the Discord channel name).
#
# Creation is always through `find_or_create_by_matrix_id!` so callers
# don't need to know whether the row is new. `discord_channel_id` is
# nullable on purpose: a row exists the moment we see an event, but the
# Discord channel is created only on the first post attempt.
class Room < ApplicationRecord
  self.table_name = "rooms"

  validates(:matrix_room_id, presence: true, uniqueness: true)

  class << self
    def find_or_create_by_matrix_id!(matrix_room_id)
      find_or_create_by!(matrix_room_id: matrix_room_id)
    end
  end

  def record_counterparty!(matrix_id:, username:)
    update!(counterparty_matrix_id: matrix_id, counterparty_username: username)
  end

  # Incremental update that only writes what we actually know about the
  # counterparty. Matrix_id alone is better than nothing (at least the channel
  # slug is stable); username arrives later via profile fetch or member state
  # and overrides.
  def ensure_counterparty!(matrix_id:, username: nil)
    changes = {}
    changes[:counterparty_matrix_id] = matrix_id if counterparty_matrix_id != matrix_id
    changes[:counterparty_username] = username if username.present? && counterparty_username != username
    update!(changes) if changes.any?
    changes
  end

  def attach_discord_channel!(channel_id)
    update!(discord_channel_id: channel_id)
  end

  def attach_webhook!(id:, token:)
    update!(discord_webhook_id: id, discord_webhook_token: token)
  end

  def clear_webhook!
    update!(discord_webhook_id: nil, discord_webhook_token: nil)
  end

  def advance_event!(event_id)
    update!(last_event_id: event_id)
  end
end
