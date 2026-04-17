# frozen_string_literal: true

class CreateSyncCheckpoints < ActiveRecord::Migration[8.1]
  def change
    create_table(:sync_checkpoints) do |t|
      t.string(:next_batch_token)
      t.datetime(:last_batch_at)
      t.timestamps
    end
  end
end
