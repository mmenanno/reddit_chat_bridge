# frozen_string_literal: true

require "bcrypt"

# Operator account with access to the web UI. Passwords are stored as
# bcrypt digests — never plaintext, never a raw hash.
#
# `first_run?` drives the setup wizard redirect: with no admin users in
# the database, the app force-routes every request to `/setup` so the
# first human through the door creates the initial admin account.
class AdminUser < ApplicationRecord
  self.table_name = "admin_users"

  MIN_PASSWORD_LENGTH = 12

  validates(:username, presence: true, uniqueness: true)
  validates(:password_digest, presence: true)

  class << self
    def first_run?
      !exists?
    end

    def create_with_password!(username:, password:)
      raise(ActiveRecord::RecordInvalid.new(new), "Password too short") if password.to_s.length < MIN_PASSWORD_LENGTH

      create!(username: username, password_digest: ::BCrypt::Password.create(password))
    end

    def authenticate(username:, password:)
      user = find_by(username: username)
      return unless user
      return unless ::BCrypt::Password.new(user.password_digest) == password

      user
    end
  end

  def update_password!(new_password)
    raise(ActiveRecord::RecordInvalid.new(self), "Password too short") if new_password.to_s.length < MIN_PASSWORD_LENGTH

    update!(password_digest: ::BCrypt::Password.create(new_password))
  end
end
