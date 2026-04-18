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

  def cache_avatar_url!(url)
    return if counterparty_avatar_url == url

    update!(counterparty_avatar_url: url, counterparty_avatar_checked_at: Time.current)
  end

  # Negative-cache: remember that we checked Reddit's profile API and it
  # returned nothing, so subsequent events don't hammer the endpoint.
  def record_avatar_lookup_miss!
    update!(counterparty_avatar_url: nil, counterparty_avatar_checked_at: Time.current)
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

  # Monotonic activity stamp used by ChannelReorderer to sort #dm-*
  # channels most-recent-first. Only writes when `time` is newer than
  # the cached value, so out-of-order backfill events don't rewind the
  # activity cursor.
  def mark_activity!(time: Time.current)
    return if last_activity_at && last_activity_at >= time

    update!(last_activity_at: time)
  end

  def archived?
    archived_at.present?
  end

  def terminated?
    terminated_at.present?
  end

  scope :not_terminated, -> { where(terminated_at: nil) }
  scope :terminated, -> { where.not(terminated_at: nil) }

  # Archive: mark and drop the cached Discord identifiers. The Poster
  # treats this as a trigger to create a fresh channel the next time a
  # message arrives — or the operator can explicitly unarchive with a
  # backfill via the UI.
  #
  # Also clears PostedEvent rows for this room: the old Discord messages
  # are gone, so the dedup entries that guarded them are meaningless and
  # would cause "Restore history" to silently skip every event.
  def archive!
    ActiveRecord::Base.transaction do
      update!(
        archived_at: Time.current,
        discord_channel_id: nil,
        discord_webhook_id: nil,
        discord_webhook_token: nil,
      )
      forget_posted_events!
    end
  end

  def unarchive!
    update!(archived_at: nil)
  end

  # Locally terminate the chat. Reddit's Matrix server refuses to honor
  # the Matrix /leave endpoint on DM rooms — their own UI only offers a
  # "Hide chat" action with the same semantics — so the best we can do
  # is mark the room terminated on our side: Discord channel gone,
  # dedup cache cleared, and the Poster/InviteHandler filter events
  # from terminated rooms so nothing gets re-bridged until the operator
  # explicitly unhides. Reversed via `restore!`.
  def terminate_locally!
    ActiveRecord::Base.transaction do
      update!(
        terminated_at: Time.current,
        discord_channel_id: nil,
        discord_webhook_id: nil,
        discord_webhook_token: nil,
      )
      forget_posted_events!
    end
  end

  # Reverse of terminate_locally!: clear the flag so future events get
  # bridged again. The next inbound Matrix message will create a fresh
  # Discord channel via the normal Poster flow.
  def restore!
    update!(terminated_at: nil)
  end

  # Wipe the dedup cache for this room. Used when the Discord channel
  # is gone (archive / termination) or just got recreated (manual delete
  # detected via rename 404), so backfills can replay without the Poster
  # skipping every event as "already posted".
  def forget_posted_events!
    PostedEvent.where(room_id: matrix_room_id).delete_all
  end
end
