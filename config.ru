# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("lib", __dir__))

require "bridge/boot"
require "bridge/application"
require "bridge/web/app"

database_path =
  case ENV.fetch("RACK_ENV", nil)
  when "production"
    "/app/state/state.sqlite3"
  when "test"
    ":memory:"
  else
    "db/development.sqlite3"
  end

Bridge::Boot.call(database_path: database_path)

# Starts the supervisor thread only when all required config is present.
# The web UI is available either way — first-run users land on /setup
# with the sync loop idle until their config is complete. After they
# finish /settings and /auth, those controllers call the same method
# and the loop spins up live; no container restart needed.
Bridge::Application.start_if_configured!
at_exit { Bridge::Application.shutdown! }

run Bridge::Web::App
