# frozen_string_literal: true

class CreateRooms < ActiveRecord::Migration[8.1]
  def change
    create_table(:rooms) do |t|
      t.string(:matrix_room_id, null: false)
      t.string(:discord_channel_id)
      t.string(:counterparty_matrix_id)
      t.string(:counterparty_username)
      t.string(:last_event_id)
      t.boolean(:is_direct, null: false, default: true)
      t.timestamps
    end

    add_index(:rooms, :matrix_room_id, unique: true)
    add_index(:rooms, :discord_channel_id, unique: true, where: "discord_channel_id IS NOT NULL")
  end
end
