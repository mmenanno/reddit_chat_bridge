# frozen_string_literal: true

source "https://rubygems.org"

# Core
gem "activerecord", "~> 8.1"
gem "activesupport", "~> 8.1"
gem "sqlite3"
gem "zeitwerk"

# Web
gem "bcrypt"
gem "puma"
gem "rack-session"
gem "sinatra"
gem "sinatra-contrib"

# Networking
gem "concurrent-ruby"
gem "faraday"
gem "faraday-retry"

# Integrations.
# Matrix is intentionally a direct Faraday client rather than a generic
# Matrix SDK gem: Reddit's homeserver ships custom event types and a
# non-standard /login flow that a generic SDK doesn't model.
gem "discordrb"
gem "websocket-client-simple"

group :development, :test do
  gem "debug", platforms: [:mri]
  gem "rake"
  gem "rubocop-mmenanno", require: false
  gem "rubocop-rake", require: false
end

group :test do
  gem "minitest", "~> 6.0"
  gem "minitest-reporters"
  gem "mocha"
  gem "rack-test"
  gem "webmock"
end
