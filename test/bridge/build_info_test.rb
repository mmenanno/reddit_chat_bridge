# frozen_string_literal: true

require "test_helper"
require "bridge/build_info"

module Bridge
  class BuildInfoTest < ActiveSupport::TestCase
    setup do
      @original_sha = ENV.fetch("BUILD_SHA", nil)
      @original_ref = ENV.fetch("BUILD_REF", nil)
      ENV["BUILD_SHA"] = nil
      ENV["BUILD_REF"] = nil
    end

    teardown do
      ENV["BUILD_SHA"] = @original_sha
      ENV["BUILD_REF"] = @original_ref
    end

    test "sha prefers BUILD_SHA when set" do
      ENV["BUILD_SHA"] = "abc1234"
      BuildInfo.expects(:git_sha).never

      assert_equal("abc1234", BuildInfo.sha)
    end

    test "ref prefers BUILD_REF when set" do
      ENV["BUILD_REF"] = "main"
      BuildInfo.expects(:git_ref).never

      assert_equal("main", BuildInfo.ref)
    end

    test "short_sha truncates long SHAs to seven characters" do
      ENV["BUILD_SHA"] = "abcdef1234567890"

      assert_equal("abcdef1", BuildInfo.short_sha)
    end

    test "short_sha returns nil when no SHA is resolvable" do
      BuildInfo.stubs(:git_sha).returns(nil)

      assert_nil(BuildInfo.short_sha)
    end

    test "label combines sha and ref when both resolve" do
      ENV["BUILD_SHA"] = "abcdef1234"
      ENV["BUILD_REF"] = "main"

      assert_equal("build abcdef1 (main)", BuildInfo.label)
    end

    test "label shows sha alone when ref is missing" do
      ENV["BUILD_SHA"] = "abcdef1234"
      BuildInfo.stubs(:git_ref).returns(nil)

      assert_equal("build abcdef1", BuildInfo.label)
    end

    test "label falls back to 'dev build' when nothing is resolvable" do
      BuildInfo.stubs(:git_sha).returns(nil)
      BuildInfo.stubs(:git_ref).returns(nil)

      assert_equal("dev build", BuildInfo.label)
    end

    test "blank ENV values are ignored in favour of git lookups" do
      ENV["BUILD_SHA"] = "   "
      BuildInfo.expects(:git_sha).returns("fromgit")

      assert_equal("fromgit", BuildInfo.sha)
    end
  end
end
