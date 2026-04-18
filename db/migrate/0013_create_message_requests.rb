# frozen_string_literal: true

class CreateMessageRequests < ActiveRecord::Migration[8.1]
  def change
    create_table(:message_requests) do |t|
      t.string(:matrix_room_id, null: false)
      t.string(:inviter_matrix_id)
      t.string(:inviter_username)
      t.string(:inviter_avatar_url)
      t.text(:preview_body)
      t.string(:discord_message_id)
      t.string(:discord_channel_id)
      t.datetime(:resolved_at)
      t.string(:decision)
      t.timestamps
    end

    add_index(:message_requests, :matrix_room_id, unique: true)
    add_index(:message_requests, :resolved_at, where: "resolved_at IS NULL")
  end
end
