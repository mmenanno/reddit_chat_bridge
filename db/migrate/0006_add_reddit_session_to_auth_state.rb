# frozen_string_literal: true

class AddRedditSessionToAuthState < ActiveRecord::Migration[8.1]
  def change
    change_table(:auth_state) do |t|
      t.text(:reddit_cookie_jar)
      t.datetime(:reddit_session_expires_at)
    end
  end
end
