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

    def setup
      super
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
  end
end
