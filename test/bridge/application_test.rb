# frozen_string_literal: true

require "test_helper"
require "bridge/application"

module Bridge
  class ApplicationTest < ActiveSupport::TestCase
    REQUIRED_KEYS = Application::REQUIRED_CONFIG_KEYS
    HOMESERVER = "https://matrix.redditspace.com"

    def setup
      super
      populate_complete_config
    end

    # ---- configured? ----

    test "configured? is true when all required AppConfig keys and an AuthState token are present" do
      assert_predicate(Application, :configured?)
    end

    test "configured? is false with no AuthState token even if all config is filled" do
      AuthState.first.update!(access_token: nil)

      refute_predicate(Application, :configured?)
    end

    test "configured? is false with a blank AuthState token" do
      AuthState.first.update!(access_token: "   ")

      refute_predicate(Application, :configured?)
    end

    test "configured? is false if any required config key is missing" do
      REQUIRED_KEYS.each do |key|
        saved = AppConfig.get(key)
        AppConfig.set(key, "")

        refute_predicate(Application, :configured?, "expected missing #{key} to make configured? false")

        AppConfig.set(key, saved)
      end
    end

    # ---- build ----

    test "build wires a Supervisor whose sync_loop dispatches through a Discord::Poster" do
      app = Application.build

      assert_instance_of(Bridge::Supervisor, app.supervisor)
      assert_instance_of(Matrix::SyncLoop, app.sync_loop)
      assert_instance_of(Discord::Poster, app.poster)
    end

    test "build constructs a Matrix::Client whose token source reads live from AuthState" do
      app = Application.build
      AuthState.update_token!(access_token: "rotated", user_id: "@t2_self:reddit.com")

      client = app.matrix_client
      # The token source is expected to be callable and return the latest DB value.
      assert_equal("rotated", client.send(:current_token))
    end

    private

    def populate_complete_config
      AppConfig.set("matrix_homeserver", HOMESERVER)
      AppConfig.set("matrix_user_id", "@t2_self:reddit.com")
      AppConfig.set("discord_bot_token", "bot_abc")
      AppConfig.set("discord_guild_id", "g1")
      AppConfig.set("discord_dms_category_id", "c1")
      AppConfig.set("discord_admin_status_channel_id", "s1")
      AppConfig.set("discord_admin_logs_channel_id", "l1")
      AuthState.update_token!(access_token: "live", user_id: "@t2_self:reddit.com")
    end
  end
end
