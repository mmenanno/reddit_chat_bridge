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

# The bridge's background thread only spins up when there's actually enough
# config for it to do anything. First-boot + setup-wizard flows hit the web
# UI with the sync loop dormant; the user flips the switch by completing
# /settings and /auth, then restarts the container (for now — a future
# slice adds a /actions "start bridge" button that spawns the thread live).
if Bridge::Application.configured?
  application = Bridge::Application.build
  application.start!
  at_exit { application.stop! }
end

run Bridge::Web::App
