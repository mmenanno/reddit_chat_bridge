# frozen_string_literal: true

# Singleton row describing the bridge's current Matrix authentication.
#
# The SQLite database holds exactly one `auth_state` row; callers reach it
# through class-level helpers rather than `AuthState.find(id)`. Storing auth
# state in the database (instead of an env var) means the operator can
# rotate the Matrix access token from the web UI without a container
# restart — the whole point of the `/auth` page.
class AuthState < ApplicationRecord
  self.table_name = "auth_state"

  class << self
    def current
      first || create!
    end

    def update_token!(access_token:, user_id:)
      row = current
      row.update!(access_token: access_token, user_id: user_id)
      mark_ok!
    end

    def mark_ok!
      current.update!(
        paused: false,
        last_ok_at: Time.current,
        consecutive_failures: 0,
        last_error: nil,
      )
    end

    def mark_failure!(reason)
      row = current
      row.update!(
        paused: true,
        consecutive_failures: row.consecutive_failures + 1,
        last_error: reason.to_s,
      )
    end

    def paused?
      current.paused?
    end

    def access_token
      current.access_token
    end

    def user_id
      current.user_id
    end
  end
end
