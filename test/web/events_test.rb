# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "bridge/web/app"

module Bridge
  module Web
    class EventsTest < ActiveSupport::TestCase
      include Rack::Test::Methods

      def app
        App
      end

      setup do
        AdminUser.create_with_password!(username: "michael", password: "hunter2hunter2")
        post("/login", username: "michael", password: "hunter2hunter2")
      end

      test "GET /events renders the empty-state copy and no pager when the log is empty" do
        get("/events")

        assert_equal(200, last_response.status)
        assert_match(/No events recorded yet/, last_response.body)
        refute_match(/Page \d+ of/, last_response.body)
      end

      test "GET /events defaults to 50 per page on page 1" do
        seed_entries(75)

        get("/events")

        # 75 entries at 50/page → Page 1 of 2. Newest (m74) renders;
        # anything from the second page (m24 and below) does not.
        assert_match(/Page 1 of 2/, last_response.body)
        assert_match(/\bm74\b/, last_response.body)
        refute_match(/\bm24\b/, last_response.body)
      end

      test "GET /events?per_page=25 uses 25, sets the cookie, and clamps to an allowed value" do
        seed_entries(75)

        get("/events?per_page=25")

        assert_match(/Page 1 of 3/, last_response.body)
        # Cookie is written so the next visit without a query param honors it.
        cookie_header = Array(last_response.headers["Set-Cookie"]).join("\n")

        assert_match(/events_per_page=25/, cookie_header)
      end

      test "GET /events honors the events_per_page cookie when no query param is set" do
        seed_entries(30)
        set_cookie("events_per_page=10")

        get("/events")

        # 30 / 10 = 3 pages when the cookie is respected.
        assert_match(/Page 1 of 3/, last_response.body)
      end

      test "GET /events ignores invalid per_page values and falls back to the default" do
        seed_entries(60)

        get("/events?per_page=999")

        # 60 / 50 default = 2 pages; a bogus value must not poison the cookie.
        assert_match(/Page 1 of 2/, last_response.body)
        cookie_header = Array(last_response.headers["Set-Cookie"]).join("\n")

        refute_match(/events_per_page=999/, cookie_header)
      end

      test "GET /events?page=2 shows the next window of entries" do
        seed_entries(75)

        get("/events?page=2")

        # Page 2 at 50/page surfaces m24..m0 and hides m74..m25.
        assert_match(/Page 2 of 2/, last_response.body)
        assert_match(/\bm24\b/, last_response.body)
        refute_match(/\bm74\b/, last_response.body)
      end

      test "GET /events?page=999 clamps to the last available page" do
        seed_entries(30)

        get("/events?per_page=10&page=999")

        # 30 entries / 10 per page = 3 pages; request for page 999 lands on 3.
        assert_equal(200, last_response.status)
        assert_match(/Page 3 of 3/, last_response.body)
      end

      test "GET /events redirects unauthenticated users to /login" do
        post("/logout")

        get("/events")

        assert_equal(302, last_response.status)
        assert_equal("/login", URI(last_response.location).path)
      end

      private

      # Seeds `count` entries with monotonically increasing timestamps so the
      # newest-first order is deterministic (m<count-1> is newest, m0 oldest).
      def seed_entries(count)
        base = 1.hour.ago
        count.times do |i|
          EventLogEntry.create!(level: "info", message: "m#{i}", created_at: base + i.seconds)
        end
      end
    end
  end
end
