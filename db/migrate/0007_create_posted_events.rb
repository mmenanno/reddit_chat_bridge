# frozen_string_literal: true

class CreatePostedEvents < ActiveRecord::Migration[8.1]
  def change
    create_table(:posted_events) do |t|
      t.string(:event_id, null: false)
      t.string(:room_id, null: false)
      t.datetime(:posted_at, null: false)
    end

    add_index(:posted_events, :event_id, unique: true)
    add_index(:posted_events, :posted_at)
  end
end
