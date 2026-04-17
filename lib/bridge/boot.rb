# frozen_string_literal: true

require "active_record"

module Bridge
  # Wires ActiveRecord to SQLite, runs pending migrations, and loads the model
  # classes. Called once at process start (web, background threads, and tests
  # share the same entry point).
  class Boot
    MIGRATIONS_PATH = File.expand_path("../../db/migrate", __dir__)
    MODELS_GLOB     = File.expand_path("../models/*.rb", __dir__)

    class << self
      def call(database_path:)
        establish_connection(database_path)
        migrate!
        load_models!
      end

      private

      def establish_connection(database_path)
        ActiveRecord::Base.establish_connection(
          adapter: "sqlite3",
          database: database_path,
        )
      end

      def migrate!
        ActiveRecord::Schema.verbose = false
        ActiveRecord::MigrationContext.new(MIGRATIONS_PATH).migrate
      end

      def load_models!
        base = File.expand_path("../models/application_record.rb", __dir__)
        require base
        Dir[MODELS_GLOB].each do |f|
          next if f == base

          require f
        end
      end
    end
  end
end
