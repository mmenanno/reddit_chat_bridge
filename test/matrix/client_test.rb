# frozen_string_literal: true

require "test_helper"
require "matrix/client"

module Matrix
  class ClientTest < ActiveSupport::TestCase
    HOMESERVER = "https://matrix.redditspace.com"
    TOKEN = "tok_abc"

    setup do
      @client = Matrix::Client.new(access_token: TOKEN, homeserver: HOMESERVER)
    end

    test "whoami returns the parsed body on 200" do
      stub_request(:get, "#{HOMESERVER}/_matrix/client/v3/account/whoami")
        .with(headers: { "Authorization" => "Bearer #{TOKEN}" })
        .to_return(
          status: 200,
          body: { user_id: "@t2_abc:reddit.com", is_guest: false }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      result = @client.whoami

      assert_equal("@t2_abc:reddit.com", result["user_id"])
      refute(result["is_guest"])
    end

    test "whoami raises Matrix::TokenError on 401 with M_UNKNOWN_TOKEN" do
      stub_request(:get, "#{HOMESERVER}/_matrix/client/v3/account/whoami")
        .to_return(
          status: 401,
          body: { errcode: "M_UNKNOWN_TOKEN", error: "bad" }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      error = assert_raises(Matrix::TokenError) { @client.whoami }

      assert_match(/M_UNKNOWN_TOKEN/, error.message)
    end

    test "accepts a callable access_token and resolves it per request" do
      values = ["tok_first", "tok_second"]
      client = Matrix::Client.new(access_token: -> { values.shift }, homeserver: HOMESERVER)
      stub_request(:get, "#{HOMESERVER}/_matrix/client/v3/account/whoami")
        .with(headers: { "Authorization" => "Bearer tok_first" })
        .to_return(status: 200, body: { user_id: "@a" }.to_json, headers: { "Content-Type" => "application/json" })
        .then
        .to_return(status: 200, body: { user_id: "@a" }.to_json, headers: { "Content-Type" => "application/json" })

      client.whoami
      stub_request(:get, "#{HOMESERVER}/_matrix/client/v3/account/whoami")
        .with(headers: { "Authorization" => "Bearer tok_second" })
        .to_return(status: 200, body: { user_id: "@a" }.to_json, headers: { "Content-Type" => "application/json" })
      client.whoami

      assert_requested(:get, "#{HOMESERVER}/_matrix/client/v3/account/whoami", times: 2)
    end

    test "whoami raises Matrix::ServerError on 5xx" do
      stub_request(:get, "#{HOMESERVER}/_matrix/client/v3/account/whoami")
        .to_return(status: 503, body: "gateway down")

      assert_raises(Matrix::ServerError) { @client.whoami }
    end

    test "sync passes timeout when no since token is given" do
      stub_request(:get, "#{HOMESERVER}/_matrix/client/v3/sync")
        .with(query: { "timeout" => "10000" })
        .to_return(
          status: 200,
          body: { next_batch: "n1", rooms: {} }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      @client.sync

      assert_requested(:get, "#{HOMESERVER}/_matrix/client/v3/sync", query: { "timeout" => "10000" })
    end

    test "sync passes both since and timeout when resuming" do
      stub_request(:get, "#{HOMESERVER}/_matrix/client/v3/sync")
        .with(query: { "timeout" => "10000", "since" => "abc" })
        .to_return(
          status: 200,
          body: { next_batch: "n2" }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      @client.sync(since: "abc", timeout_ms: 10_000)

      assert_requested(
        :get,
        "#{HOMESERVER}/_matrix/client/v3/sync",
        query: { "timeout" => "10000", "since" => "abc" },
      )
    end

    test "sync returns the parsed body" do
      stub_request(:get, "#{HOMESERVER}/_matrix/client/v3/sync")
        .with(query: hash_including("timeout" => "10000"))
        .to_return(
          status: 200,
          body: { next_batch: "n3", rooms: { join: {} } }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      body = @client.sync

      assert_equal("n3", body["next_batch"])
      assert_equal({}, body["rooms"]["join"])
    end

    test "send_message PUTs to the escaped room path with the given txn_id" do
      room = "!B3f4egr29DfLGF1wtJLCK7JPIdJHfTDb9rLbRcP4AX4:reddit.com"
      txn  = "txn-0001"
      escaped = "%21B3f4egr29DfLGF1wtJLCK7JPIdJHfTDb9rLbRcP4AX4%3Areddit.com"

      stub_request(:put, "#{HOMESERVER}/_matrix/client/v3/rooms/#{escaped}/send/m.room.message/#{txn}")
        .with(
          headers: {
            "Authorization" => "Bearer #{TOKEN}",
            "Content-Type" => "application/json",
          },
          body: { msgtype: "m.text", body: "hello" }.to_json,
        )
        .to_return(
          status: 200,
          body: { event_id: "$evt_1" }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      event_id = @client.send_message(room_id: room, body: "hello", txn_id: txn)

      assert_equal("$evt_1", event_id)
    end

    SEND_PATH_PATTERN = %r{/_matrix/client/v3/rooms/[^/]+/send/m\.room\.message/[^/]+\z}

    test "send_message raises Matrix::TokenError on 401" do
      stub_request(:put, SEND_PATH_PATTERN)
        .to_return(
          status: 401,
          body: { errcode: "M_UNKNOWN_TOKEN", error: "nope" }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      assert_raises(Matrix::TokenError) do
        @client.send_message(room_id: "!r:reddit.com", body: "x", txn_id: "t")
      end
    end
  end
end
