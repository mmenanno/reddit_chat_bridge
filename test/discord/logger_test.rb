# frozen_string_literal: true

require "test_helper"
require "discord/client"
require "discord/logger"

module Discord
  class LoggerTest < ActiveSupport::TestCase
    LOGS_CHANNEL = "888"

    setup do
      @client = Discord::Client.new(bot_token: "tok")
      @logger = Discord::Logger.new(client: @client, logs_channel_id: LOGS_CHANNEL)
    end

    test "info posts to the logs channel with an info prefix" do
      @client.expects(:send_message).with(
        channel_id: LOGS_CHANNEL,
        content: regexp_matches(/\A`INFO`.*event dispatched\z/),
      ).returns("m")

      @logger.info("event dispatched")
    end

    test "warn posts to the logs channel with a warn prefix" do
      @client.expects(:send_message).with(
        channel_id: LOGS_CHANNEL,
        content: regexp_matches(/\A`WARN`.*retrying\z/),
      ).returns("m")

      @logger.warn("retrying")
    end

    test "error posts to the logs channel with an error prefix" do
      @client.expects(:send_message).with(
        channel_id: LOGS_CHANNEL,
        content: regexp_matches(/\A`ERROR`.*boom\z/),
      ).returns("m")

      @logger.error("boom")
    end

    test "swallows client errors so a broken log channel never takes the bridge down" do
      @client.expects(:send_message).raises(Discord::ServerError, "503")

      assert_nothing_raised { @logger.info("anything") }
    end
  end
end
