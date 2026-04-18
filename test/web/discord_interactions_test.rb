# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "bridge/application"
require "bridge/web/app"
require "ed25519"

module Bridge
  module Web
    class DiscordInteractionsTest < ActiveSupport::TestCase
      include Rack::Test::Methods

      def app
        App
      end

      SIGNING_KEY = Ed25519::SigningKey.generate
      VERIFY_KEY  = SIGNING_KEY.verify_key
      PUBLIC_KEY_HEX = VERIFY_KEY.to_bytes.unpack1("H*")

      def setup
        super
        AppConfig.set("discord_public_key", PUBLIC_KEY_HEX)
        AppConfig.set("discord_guild_id", "111")
        AppConfig.set("discord_admin_commands_channel_id", "222")
      end

      test "POST /discord/interactions rejects an unsigned request with 401" do
        post "/discord/interactions", "{}", { "CONTENT_TYPE" => "application/json" }

        assert_equal(401, last_response.status)
      end

      test "POST /discord/interactions rejects a signature over the wrong body with 401" do
        ts = "42"
        sig = SIGNING_KEY.sign("#{ts}ORIGINAL").unpack1("H*")
        header("X-Signature-Ed25519", sig)
        header("X-Signature-Timestamp", ts)

        post "/discord/interactions", "TAMPERED", { "CONTENT_TYPE" => "application/json" }

        assert_equal(401, last_response.status)
      end

      test "responds to a signed PING with PONG" do
        body = JSON.generate({ type: 1 })
        ts = "42"
        sig = SIGNING_KEY.sign("#{ts}#{body}").unpack1("H*")
        header("X-Signature-Ed25519", sig)
        header("X-Signature-Timestamp", ts)

        post "/discord/interactions", body, { "CONTENT_TYPE" => "application/json" }

        assert_equal(200, last_response.status)
        assert_equal(1, JSON.parse(last_response.body)["type"])
      end

      test "dispatches a signed /ping application command" do
        body = JSON.generate({
          type: 2, guild_id: "111", channel_id: "222", data: { name: "ping" },
        })
        ts = "42"
        sig = SIGNING_KEY.sign("#{ts}#{body}").unpack1("H*")
        header("X-Signature-Ed25519", sig)
        header("X-Signature-Timestamp", ts)

        post "/discord/interactions", body, { "CONTENT_TYPE" => "application/json" }

        parsed = JSON.parse(last_response.body)

        assert_equal(4, parsed["type"])
        assert_match(/pong/i, parsed["data"]["content"])
      end
    end
  end
end
