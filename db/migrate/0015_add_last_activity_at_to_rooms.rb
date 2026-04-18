# frozen_string_literal: true

class AddLastActivityAtToRooms < ActiveRecord::Migration[8.1]
  def change
    add_column(:rooms, :last_activity_at, :datetime)
    add_index(:rooms, :last_activity_at)
  end
end
