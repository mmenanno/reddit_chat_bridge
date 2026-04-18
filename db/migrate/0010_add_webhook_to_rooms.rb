# frozen_string_literal: true

class AddWebhookToRooms < ActiveRecord::Migration[8.1]
  def change
    add_column(:rooms, :discord_webhook_id, :string)
    add_column(:rooms, :discord_webhook_token, :string)
  end
end
