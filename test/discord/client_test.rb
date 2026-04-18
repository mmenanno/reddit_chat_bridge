# frozen_string_literal: true

require "test_helper"
require "discord/client"

module Discord
  class ClientTest < ActiveSupport::TestCase
    BASE = "https://discord.com/api/v10"
    TOKEN = "bot_abc"
    GUILD = "111111111111111111"
    CATEGORY = "222222222222222222"
    CHANNEL = "333333333333333333"

    setup do
      @client = Discord::Client.new(bot_token: TOKEN)
    end

    test "create_channel POSTs to the guild with the expected payload" do
      stub_request(:post, "#{BASE}/guilds/#{GUILD}/channels")
        .with(
          headers: {
            "Authorization" => "Bot #{TOKEN}",
            "Content-Type" => "application/json",
          },
          body: { name: "dm-nothnnn", type: 0, parent_id: CATEGORY }.to_json,
        )
        .to_return(
          status: 201,
          body: { id: CHANNEL, name: "dm-nothnnn", type: 0, parent_id: CATEGORY }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      id = @client.create_channel(guild_id: GUILD, name: "dm-nothnnn", parent_id: CATEGORY)

      assert_equal(CHANNEL, id)
    end

    test "create_channel omits parent_id when none is supplied" do
      stub_request(:post, "#{BASE}/guilds/#{GUILD}/channels")
        .with(body: { name: "dm-foo", type: 0 }.to_json)
        .to_return(
          status: 201,
          body: { id: CHANNEL }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      id = @client.create_channel(guild_id: GUILD, name: "dm-foo")

      assert_equal(CHANNEL, id)
    end

    test "create_channel raises Discord::AuthError on 401" do
      stub_request(:post, "#{BASE}/guilds/#{GUILD}/channels")
        .to_return(status: 401, body: { message: "401: Unauthorized" }.to_json)

      assert_raises(Discord::AuthError) do
        @client.create_channel(guild_id: GUILD, name: "x")
      end
    end

    test "create_channel raises Discord::AuthError on 403" do
      stub_request(:post, "#{BASE}/guilds/#{GUILD}/channels")
        .to_return(status: 403, body: { message: "Missing Permissions" }.to_json)

      assert_raises(Discord::AuthError) do
        @client.create_channel(guild_id: GUILD, name: "x")
      end
    end

    test "send_message POSTs content to the right channel and returns the message id" do
      stub_request(:post, "#{BASE}/channels/#{CHANNEL}/messages")
        .with(
          headers: { "Authorization" => "Bot #{TOKEN}" },
          body: { content: "hello" }.to_json,
        )
        .to_return(
          status: 200,
          body: { id: "msg_1", content: "hello" }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      id = @client.send_message(channel_id: CHANNEL, content: "hello")

      assert_equal("msg_1", id)
    end

    test "send_message raises Discord::NotFound on 404" do
      stub_request(:post, "#{BASE}/channels/#{CHANNEL}/messages")
        .to_return(status: 404, body: { message: "Unknown Channel" }.to_json)

      assert_raises(Discord::NotFound) do
        @client.send_message(channel_id: CHANNEL, content: "hi")
      end
    end

    test "send_message raises Discord::RateLimited with retry_after_ms on 429" do
      stub_request(:post, "#{BASE}/channels/#{CHANNEL}/messages")
        .to_return(
          status: 429,
          body: { retry_after: 1.5, message: "You are being rate limited." }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      error = assert_raises(Discord::RateLimited) do
        @client.send_message(channel_id: CHANNEL, content: "hi")
      end

      assert_equal(1500, error.retry_after_ms)
    end

    test "send_message raises Discord::ServerError on 5xx" do
      stub_request(:post, "#{BASE}/channels/#{CHANNEL}/messages")
        .to_return(status: 502, body: "bad gateway")

      assert_raises(Discord::ServerError) do
        @client.send_message(channel_id: CHANNEL, content: "hi")
      end
    end

    test "get_channel returns the parsed channel payload" do
      stub_request(:get, "#{BASE}/channels/#{CHANNEL}")
        .with(headers: { "Authorization" => "Bot #{TOKEN}" })
        .to_return(
          status: 200,
          body: { id: CHANNEL, name: "dm-foo", type: 0 }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      channel = @client.get_channel(CHANNEL)

      assert_equal("dm-foo", channel["name"])
    end

    test "get_channel raises Discord::NotFound on 404" do
      stub_request(:get, "#{BASE}/channels/#{CHANNEL}")
        .to_return(status: 404, body: { message: "Unknown Channel" }.to_json)

      assert_raises(Discord::NotFound) do
        @client.get_channel(CHANNEL)
      end
    end

    # ---- reorder_channels ----

    test "reorder_channels PATCHes guild channels with the [id, position] payload" do
      stub_request(:patch, "#{BASE}/guilds/#{GUILD}/channels")
        .with(
          headers: { "Authorization" => "Bot #{TOKEN}" },
          body: [{ id: "a", position: 0 }, { id: "b", position: 1 }].to_json,
        )
        .to_return(status: 204, body: "")

      assert_equal(
        :ok,
        @client.reorder_channels(
          guild_id: GUILD,
          positions: [{ id: "a", position: 0 }, { id: "b", position: 1 }],
        ),
      )
    end

    # ---- delete_channel ----

    test "delete_channel DELETEs the channel with the bot token" do
      stub_request(:delete, "#{BASE}/channels/#{CHANNEL}")
        .with(headers: { "Authorization" => "Bot #{TOKEN}" })
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      assert_equal(:ok, @client.delete_channel(channel_id: CHANNEL))
    end

    test "delete_channel raises Discord::NotFound when the channel is already gone" do
      stub_request(:delete, "#{BASE}/channels/#{CHANNEL}")
        .to_return(status: 404, body: { message: "Unknown Channel" }.to_json)

      assert_raises(Discord::NotFound) { @client.delete_channel(channel_id: CHANNEL) }
    end

    # ---- delete_message ----

    test "delete_message DELETEs the specific message with the bot token" do
      stub_request(:delete, "#{BASE}/channels/#{CHANNEL}/messages/msg_1")
        .with(headers: { "Authorization" => "Bot #{TOKEN}" })
        .to_return(status: 204, body: "")

      assert_equal(:ok, @client.delete_message(channel_id: CHANNEL, message_id: "msg_1"))
    end

    # ---- webhooks ----

    test "create_webhook POSTs to the channel and returns the webhook id + token" do
      stub_request(:post, "#{BASE}/channels/#{CHANNEL}/webhooks")
        .with(
          headers: { "Authorization" => "Bot #{TOKEN}" },
          body: { name: "Reddit Chat Bridge" }.to_json,
        )
        .to_return(
          status: 200,
          body: { id: "wh_1", token: "tok_1", channel_id: CHANNEL }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      hook = @client.create_webhook(channel_id: CHANNEL, name: "Reddit Chat Bridge")

      assert_equal("wh_1", hook["id"])
      assert_equal("tok_1", hook["token"])
    end

    test "execute_webhook POSTs identity overrides and does not use the bot token" do
      stub_request(:post, "#{BASE}/webhooks/wh_1/tok_1?wait=true")
        .with(body: { content: "hi", username: "testuser", avatar_url: "https://img/h.png" }.to_json)
        .with { |req| !req.headers.key?("Authorization") }
        .to_return(
          status: 200,
          body: { id: "msg_9" }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      id = @client.execute_webhook(
        webhook_id: "wh_1",
        webhook_token: "tok_1",
        payload: { content: "hi", username: "testuser", avatar_url: "https://img/h.png" },
      )

      assert_equal("msg_9", id)
    end

    test "execute_webhook raises Discord::NotFound when the webhook has been deleted" do
      stub_request(:post, "#{BASE}/webhooks/wh_1/tok_1?wait=true")
        .to_return(status: 404, body: { message: "Unknown Webhook" }.to_json)

      assert_raises(Discord::NotFound) do
        @client.execute_webhook(webhook_id: "wh_1", webhook_token: "tok_1", payload: { content: "x" })
      end
    end

    test "execute_webhook surfaces Discord::RateLimited with retry_after_ms" do
      stub_request(:post, "#{BASE}/webhooks/wh_1/tok_1?wait=true")
        .to_return(
          status: 429,
          body: { retry_after: 0.25, message: "slow down" }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      error = assert_raises(Discord::RateLimited) do
        @client.execute_webhook(webhook_id: "wh_1", webhook_token: "tok_1", payload: { content: "x" })
      end

      assert_equal(250, error.retry_after_ms)
    end
  end
end
