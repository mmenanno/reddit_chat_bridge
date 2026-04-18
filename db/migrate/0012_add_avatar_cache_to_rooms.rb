# frozen_string_literal: true

class AddAvatarCacheToRooms < ActiveRecord::Migration[8.1]
  def change
    add_column(:rooms, :counterparty_avatar_url, :string)
    add_column(:rooms, :counterparty_avatar_checked_at, :datetime)
  end
end
