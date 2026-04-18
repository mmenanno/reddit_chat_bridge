# frozen_string_literal: true

require "test_helper"
require "matrix/media_resolver"

module Matrix
  class MediaResolverTest < ActiveSupport::TestCase
    setup do
      @resolver = MediaResolver.new(homeserver: "https://matrix.redditspace.com")
    end

    test "resolves a well-formed mxc:// URL" do
      url = @resolver.resolve("mxc://matrix.redditspace.com/abc123xyz")

      assert_equal(
        "https://matrix.redditspace.com/_matrix/media/v3/download/matrix.redditspace.com/abc123xyz",
        url,
      )
    end

    test "returns nil for nil and empty inputs" do
      assert_nil(@resolver.resolve(nil))
      assert_nil(@resolver.resolve(""))
    end

    test "returns nil for non-mxc URLs" do
      assert_nil(@resolver.resolve("https://example.com/foo"))
      assert_nil(@resolver.resolve("mxc://no-media-id"))
    end

    test "strips a trailing slash from the homeserver URL" do
      resolver = MediaResolver.new(homeserver: "https://matrix.redditspace.com/")

      assert_equal(
        "https://matrix.redditspace.com/_matrix/media/v3/download/matrix.redditspace.com/id",
        resolver.resolve("mxc://matrix.redditspace.com/id"),
      )
    end
  end
end
