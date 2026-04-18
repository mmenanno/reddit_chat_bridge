# frozen_string_literal: true

require "test_helper"
require "discord/client"
require "discord/admin_notifier"

module Discord
  class AdminNotifierTest < ActiveSupport::TestCase
    STATUS_CHANNEL = "999"

    setup do
      @client = Discord::Client.new(bot_token: "tok")
      @notifier = Discord::AdminNotifier.new(client: @client, status_channel_id: STATUS_CHANNEL)
    end

    test "info posts to the status channel with a green indicator" do
      @client.expects(:send_message).with(
        channel_id: STATUS_CHANNEL,
        content: regexp_matches(/🟢.*started/),
      ).returns("m")

      @notifier.info("started at 10:00")
    end

    test "warn posts to the status channel with a yellow indicator" do
      @client.expects(:send_message).with(
        channel_id: STATUS_CHANNEL,
        content: regexp_matches(/🟡.*slow/),
      ).returns("m")

      @notifier.warn("sync is slow")
    end

    test "critical posts to the status channel with a red indicator and @everyone" do
      @client.expects(:send_message).with(
        channel_id: STATUS_CHANNEL,
        content: regexp_matches(/🔴.*@everyone.*Matrix auth/m),
      ).returns("m")

      @notifier.critical("Matrix auth failed")
    end

    test "critical can omit @everyone when not urgent enough to page" do
      @client.expects(:send_message).with(
        channel_id: STATUS_CHANNEL,
        content: regexp_matches(/\A🔴[^@]*bad thing\z/),
      ).returns("m")

      @notifier.critical("bad thing", ping_everyone: false)
    end

    test "swallows client errors so a broken admin channel never takes the bridge down" do
      @client.expects(:send_message).raises(Discord::ServerError, "503")

      assert_nothing_raised { @notifier.info("anything") }
    end
  end
end
