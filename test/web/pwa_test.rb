# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "bridge/web/app"

module Bridge
  module Web
    class PWATest < ActiveSupport::TestCase
      include Rack::Test::Methods

      def app
        App
      end

      # ---- /manifest.webmanifest ----

      test "GET /manifest.webmanifest returns 200 unauthenticated" do
        get "/manifest.webmanifest"

        assert_equal(200, last_response.status)
      end

      test "GET /manifest.webmanifest serves application/manifest+json" do
        get "/manifest.webmanifest"

        assert_match(%r{application/manifest\+json}, last_response.content_type)
      end

      test "GET /manifest.webmanifest body names the app and sets display: standalone" do
        get "/manifest.webmanifest"
        body = JSON.parse(last_response.body)

        assert_equal("Reddit Chat Bridge", body["name"])
        assert_equal("standalone", body["display"])
      end

      test "GET /manifest.webmanifest declares the app scope at /" do
        get "/manifest.webmanifest"
        body = JSON.parse(last_response.body)

        assert_equal("/", body["start_url"])
      end

      test "GET /manifest.webmanifest lists a 192x192 icon for Android home-screen" do
        get "/manifest.webmanifest"
        icons = JSON.parse(last_response.body).fetch("icons")

        assert(icons.any? { |i| i["sizes"] == "192x192" }, "must list a 192x192 icon")
      end

      test "GET /manifest.webmanifest lists a maskable 512x512 icon for adaptive renderers" do
        get "/manifest.webmanifest"
        icons = JSON.parse(last_response.body).fetch("icons")

        assert(
          icons.any? { |i| i["sizes"] == "512x512" && i["purpose"] == "maskable" },
          "must list a maskable 512x512 icon",
        )
      end

      # ---- /sw.js ----

      test "GET /sw.js returns 200 unauthenticated" do
        get "/sw.js"

        assert_equal(200, last_response.status)
      end

      test "GET /sw.js serves JavaScript with no-cache header" do
        get "/sw.js"

        assert_match(/javascript/, last_response.content_type)
        assert_equal("no-cache", last_response.headers["Cache-Control"])
      end

      test "GET /sw.js body interpolates the project VERSION into the cache key" do
        get "/sw.js"

        assert_match(/VERSION\s*=\s*"v#{Regexp.escape(Bridge::BuildInfo.version)}"/, last_response.body)
      end

      test "GET /sw.js precaches the versioned stylesheet URL" do
        get "/sw.js"

        assert_includes(last_response.body, "/application-#{Bridge::BuildInfo.version}.css")
      end

      # ---- versioned stylesheet ----

      test "GET /application-<version>.css serves the stylesheet" do
        get "/application-#{Bridge::BuildInfo.version}.css"

        assert_equal(200, last_response.status)
      end

      test "GET /application-<version>.css is marked immutable for aggressive caching" do
        get "/application-#{Bridge::BuildInfo.version}.css"
        cache_control = last_response.headers["Cache-Control"].to_s

        assert_includes(cache_control, "immutable")
        assert_match(/max-age=\d{6,}/, cache_control)
      end

      test "GET bare /application.css falls back to Sinatra's default caching" do
        get "/application.css"

        refute_includes(last_response.headers["Cache-Control"].to_s, "immutable")
      end

      # ---- /offline.html ----

      test "GET /offline.html returns 200 unauthenticated" do
        get "/offline.html"

        assert_equal(200, last_response.status)
      end

      test "GET /offline.html body announces the bridge is unreachable" do
        get "/offline.html"

        assert_match(/Bridge unreachable/i, last_response.body)
      end

      # ---- icon assets ----

      test "PWA icon paths return 200 unauthenticated" do
        [
          "/icons/icon-180.png",
          "/icons/icon-192.png",
          "/icons/icon-512.png",
          "/icons/icon-512-maskable.png",
        ].each do |path|
          get path

          assert_equal(200, last_response.status, "#{path} should be served publicly")
        end
      end

      # ---- regression: protected routes still require auth ----

      test "GET / still redirects to /setup when no admin exists" do
        get "/"

        assert_equal(302, last_response.status)
        assert_equal("/setup", URI(last_response.location).path)
      end
    end
  end
end
