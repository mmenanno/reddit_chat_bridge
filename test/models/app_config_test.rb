# frozen_string_literal: true

require "test_helper"

class AppConfigTest < ActiveSupport::TestCase
  test "get returns nil for a missing key" do
    assert_nil(AppConfig.get("nothing"))
  end

  test "set stores a value that get can retrieve" do
    AppConfig.set("discord_guild_id", "12345")

    assert_equal("12345", AppConfig.get("discord_guild_id"))
  end

  test "set overwrites an existing value" do
    AppConfig.set("port", "80")
    AppConfig.set("port", "4567")

    assert_equal("4567", AppConfig.get("port"))
  end

  test "fetch returns the provided default when the key is missing" do
    assert_equal("fallback", AppConfig.fetch("missing", "fallback"))
  end

  test "fetch returns the stored value when present, ignoring the default" do
    AppConfig.set("discord_guild_id", "1234567890")

    assert_equal("1234567890", AppConfig.fetch("discord_guild_id", "ignored"))
  end

  test "set is idempotent for the same key and value" do
    AppConfig.set("log_level", "info")
    row_id = AppConfig.find_by(key: "log_level").id
    AppConfig.set("log_level", "info")

    assert_equal(1, AppConfig.where(key: "log_level").count)
    assert_equal(row_id, AppConfig.find_by(key: "log_level").id)
  end
end
