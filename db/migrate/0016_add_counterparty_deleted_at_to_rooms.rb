# frozen_string_literal: true

class AddCounterpartyDeletedAtToRooms < ActiveRecord::Migration[8.1]
  def change
    add_column(:rooms, :counterparty_deleted_at, :datetime)

    reversible do |dir|
      dir.up do
        # Pre-flag rows whose counterparty_username got overwritten with
        # Reddit's "[deleted]" sentinel before we tracked it as a flag.
        # Clear the bogus name so the UI falls back to "unresolved" +
        # deleted badge instead of literally rendering "[deleted]".
        execute(<<~SQL.squish)
          UPDATE rooms
          SET counterparty_deleted_at = CURRENT_TIMESTAMP,
              counterparty_username = NULL
          WHERE counterparty_username = '[deleted]'
        SQL
      end
    end
  end
end
