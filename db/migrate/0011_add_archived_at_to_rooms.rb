# frozen_string_literal: true

class AddArchivedAtToRooms < ActiveRecord::Migration[8.1]
  def change
    add_column(:rooms, :archived_at, :datetime)
    add_index(:rooms, :archived_at, where: "archived_at IS NOT NULL")
  end
end
