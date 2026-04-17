# frozen_string_literal: true

source "https://rubygems.org"

ruby "4.0.2"

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

# Integrations
gem "discordrb"
gem "websocket-client-simple"

group :development, :test do
  gem "debug", platforms: [:mri]
  gem "rake"
  gem "rubocop-mmenanno", require: false
end

group :test do
  gem "minitest", "~> 5.25"
  gem "minitest-reporters"
  gem "mocha"
  gem "rack-test"
  gem "webmock"
end
