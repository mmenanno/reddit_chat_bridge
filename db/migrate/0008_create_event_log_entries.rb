# frozen_string_literal: true

class CreateEventLogEntries < ActiveRecord::Migration[8.1]
  def change
    create_table(:event_log_entries) do |t|
      t.string(:level, null: false)
      t.string(:source)
      t.text(:message, null: false)
      t.text(:context)
      t.datetime(:created_at, null: false)
    end

    add_index(:event_log_entries, :created_at)
    add_index(:event_log_entries, :level)
  end
end
