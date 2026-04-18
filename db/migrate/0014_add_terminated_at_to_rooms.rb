# frozen_string_literal: true

class AddTerminatedAtToRooms < ActiveRecord::Migration[8.1]
  def change
    add_column(:rooms, :terminated_at, :datetime)
    add_index(:rooms, :terminated_at, where: "terminated_at IS NULL")
  end
end
