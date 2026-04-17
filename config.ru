# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("lib", __dir__))

require "bridge/boot"
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

run Bridge::Web::App
