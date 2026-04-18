# frozen_string_literal: true

class CreateOutboundMessages < ActiveRecord::Migration[8.1]
  def change
    create_table(:outbound_messages) do |t|
      t.string(:txn_id, null: false)
      t.string(:discord_message_id)
      t.string(:matrix_room_id, null: false)
      t.string(:matrix_event_id)
      t.string(:status, null: false, default: "pending")
      t.text(:last_error)
      t.datetime(:sent_at)
      t.timestamps
    end

    add_index(:outbound_messages, :txn_id, unique: true)
    add_index(:outbound_messages, :matrix_event_id)
    add_index(:outbound_messages, :discord_message_id)
  end
end
