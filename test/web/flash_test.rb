# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "bridge/web/app"

module Bridge
  module Web
    # Round-trips the session flash across a redirect. The admin UI's PRG
    # conversion leans on this: POSTs write `session[:flash]`, redirect,
    # the GET renders the banner, and then a plain reload shows no banner.
    class FlashTest < ActiveSupport::TestCase
      include Rack::Test::Methods

      def app
        App
      end

      setup do
        AdminUser.create_with_password!(username: "michael", password: "hunter2hunter2")
        post("/login", username: "michael", password: "hunter2hunter2")
      end

      test "POST that sets a notice + redirects surfaces the banner on the next GET" do
        post("/settings")

        assert_equal(302, last_response.status)
        follow_redirect!

        assert_equal(200, last_response.status)
        assert_match(/Settings saved/, last_response.body)
      end

      test "flash is consumed after one render — reload clears the banner" do
        post("/settings")
        follow_redirect!

        assert_match(/Settings saved/, last_response.body)

        get("/settings")

        refute_match(/Settings saved/, last_response.body)
      end

      test "flash error from a failed auth POST survives the redirect" do
        post("/auth", access_token: "   ")

        assert_equal(302, last_response.status)
        follow_redirect!

        assert_match(/Paste an access token/, last_response.body)
      end
    end
  end
end
