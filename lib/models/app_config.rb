# frozen_string_literal: true

# Persistent key/value configuration store. Holds everything that used to be
# environment variables in earlier designs: Discord IDs, Matrix identifiers,
# any setting that the operator edits through `/settings` in the web UI.
#
# Keys are strings; values are stored as text. Callers that need typed values
# convert on their own side — this class deliberately stays string-in,
# string-out so the DB schema is simple and the UI can always render and
# round-trip a plain text field.
class AppConfig < ApplicationRecord
  self.table_name = "app_configs"

  validates(:key, presence: true, uniqueness: true)

  class << self
    def get(key)
      where(key: key).pick(:value)
    end

    def set(key, value)
      row = find_or_initialize_by(key: key)
      row.value = value
      row.save!
      value
    end

    def fetch(key, default = nil)
      value = get(key)
      value.nil? ? default : value
    end
  end
end
