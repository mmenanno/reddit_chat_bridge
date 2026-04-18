# frozen_string_literal: true

# One row per pending Reddit chat invite ("message request" in Reddit's
# UI). Created by the Matrix::InviteHandler off the /sync response's
# `rooms.invite` section and resolved when the operator clicks Approve
# / Decline in Discord or the web UI.
#
# Why a separate table (not a status column on Room): an invite may
# never become an active Room — if the operator declines, we leave the
# Matrix room and the invite is gone. Keeping invites distinct avoids
# a scope-filter maze when querying "active bridged rooms".
class MessageRequest < ApplicationRecord
  self.table_name = "message_requests"

  APPROVED = "approved"
  DECLINED = "declined"

  validates(:matrix_room_id, presence: true, uniqueness: true)

  scope :pending, -> { where(resolved_at: nil).order(created_at: :asc) }
  scope :recent_resolved, -> { where.not(resolved_at: nil).order(resolved_at: :desc) }

  def pending?
    resolved_at.nil?
  end

  def approved?
    decision == APPROVED
  end

  def declined?
    decision == DECLINED
  end

  def resolve!(decision:, at: Time.current)
    update!(decision: decision, resolved_at: at)
  end

  def attach_discord_message!(channel_id:, message_id:)
    update!(discord_channel_id: channel_id, discord_message_id: message_id)
  end

  def display_name
    return inviter_username if inviter_username.present?
    return matrix_id_localpart(inviter_matrix_id) if inviter_matrix_id.present?

    "unknown"
  end

  private

  def matrix_id_localpart(matrix_id)
    matrix_id.to_s.sub(/\A@/, "").sub(/:.+\z/, "")
  end
end
