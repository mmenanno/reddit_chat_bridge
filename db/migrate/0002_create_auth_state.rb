# frozen_string_literal: true

class CreateAuthState < ActiveRecord::Migration[8.1]
  def change
    create_table(:auth_state) do |t|
      t.string(:access_token)
      t.string(:user_id)
      t.boolean(:paused, null: false, default: false)
      t.datetime(:last_ok_at)
      t.integer(:consecutive_failures, null: false, default: 0)
      t.text(:last_error)
      t.timestamps
    end
  end
end
