# frozen_string_literal: true

class AddPausedReasonToAuthState < ActiveRecord::Migration[8.1]
  def change
    add_column(:auth_state, :paused_reason, :string)

    reversible do |dir|
      dir.up do
        # Pre-1.3 rows that are already paused were paused because
        # mark_failure! flipped them — no operator path existed yet.
        # Backfill so paused_by_operator? reports correctly on upgrade.
        execute(<<~SQL.squish)
          UPDATE auth_state
          SET paused_reason = 'token_rejected'
          WHERE paused = 1 AND paused_reason IS NULL
        SQL
      end
    end
  end
end
