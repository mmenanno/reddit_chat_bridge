# frozen_string_literal: true

require "test_helper"
require "reddit/profile_client"

module Reddit
  class ProfileClientTest < ActiveSupport::TestCase
    BASE = "https://www.reddit.com"
    UA = Reddit::ProfileClient::USER_AGENT

    def setup
      super
      @client = Reddit::ProfileClient.new
    end

    test "returns the snoovatar URL when the user has one" do
      stub_request(:get, "#{BASE}/user/jinxieRay/about.json")
        .with(headers: { "User-Agent" => UA })
        .to_return(
          status: 200,
          body: { data: { snoovatar_img: "https://i.redd.it/snoovatar/x.png?width=256", icon_img: "https://ignored" } }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      assert_equal("https://i.redd.it/snoovatar/x.png", @client.fetch_avatar_url("jinxieRay"))
    end

    test "falls back to icon_img when no snoovatar is set" do
      stub_request(:get, "#{BASE}/user/plainuser/about.json")
        .to_return(
          status: 200,
          body: { data: { snoovatar_img: "", icon_img: "https://styles.redditmedia.com/t5_abc/styles/profileIcon.png" } }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      assert_equal(
        "https://styles.redditmedia.com/t5_abc/styles/profileIcon.png",
        @client.fetch_avatar_url("plainuser"),
      )
    end

    test "returns nil when icon_img is a default Snoo and there's no snoovatar" do
      stub_request(:get, "#{BASE}/user/default/about.json")
        .to_return(
          status: 200,
          body: { data: { snoovatar_img: "", icon_img: "https://www.redditstatic.com/avatars/avatar_default_12.png?foo=bar" } }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      assert_nil(@client.fetch_avatar_url("default"))
    end

    test "returns nil on 404" do
      stub_request(:get, "#{BASE}/user/ghost/about.json")
        .to_return(status: 404, body: "{}", headers: { "Content-Type" => "application/json" })

      assert_nil(@client.fetch_avatar_url("ghost"))
    end

    test "returns nil when Faraday raises" do
      stub_request(:get, "#{BASE}/user/broken/about.json").to_raise(Faraday::ConnectionFailed.new("boom"))

      assert_nil(@client.fetch_avatar_url("broken"))
    end

    test "returns nil for a blank username without hitting the network" do
      assert_nil(@client.fetch_avatar_url(""))
      assert_nil(@client.fetch_avatar_url(nil))
    end

    test "strips query params so cached URLs stay stable" do
      stub_request(:get, "#{BASE}/user/params/about.json")
        .to_return(
          status: 200,
          body: { data: { snoovatar_img: "https://i.redd.it/avatar.png?width=512&height=512&crop=smart" } }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      assert_equal("https://i.redd.it/avatar.png", @client.fetch_avatar_url("params"))
    end
  end
end
