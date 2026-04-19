# frozen_string_literal: true

require "test_helper"
require "bridge/build_info"

module Bridge
  class BuildInfoTest < ActiveSupport::TestCase
    setup do
      @original_sha = ENV.fetch("BUILD_SHA", nil)
      @original_ref = ENV.fetch("BUILD_REF", nil)
      @original_version = ENV.fetch("BUILD_VERSION", nil)
      ENV["BUILD_SHA"] = nil
      ENV["BUILD_REF"] = nil
      ENV["BUILD_VERSION"] = nil
    end

    teardown do
      ENV["BUILD_SHA"] = @original_sha
      ENV["BUILD_REF"] = @original_ref
      ENV["BUILD_VERSION"] = @original_version
    end

    # ---- version ----

    test "version prefers BUILD_VERSION env when set" do
      ENV["BUILD_VERSION"] = "2.3.4"
      BuildInfo.expects(:version_file).never

      assert_equal("2.3.4", BuildInfo.version)
    end

    test "version reads the VERSION file when BUILD_VERSION is absent" do
      BuildInfo.stubs(:version_file).returns("1.0.0")

      assert_equal("1.0.0", BuildInfo.version)
    end

    test "version falls back to UNKNOWN_VERSION when neither source resolves" do
      BuildInfo.stubs(:version_file).returns(nil)

      assert_equal(BuildInfo::UNKNOWN_VERSION, BuildInfo.version)
    end

    # ---- sha / ref ----

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

    # ---- label ----

    test "label combines version, sha, and ref when all resolve" do
      ENV["BUILD_VERSION"] = "1.2.3"
      ENV["BUILD_SHA"] = "abcdef1234"
      ENV["BUILD_REF"] = "main"

      assert_equal("v1.2.3 · build abcdef1 (main)", BuildInfo.label)
    end

    test "label drops ref when only version + sha resolve" do
      ENV["BUILD_VERSION"] = "1.2.3"
      ENV["BUILD_SHA"] = "abcdef1234"
      BuildInfo.stubs(:git_ref).returns(nil)

      assert_equal("v1.2.3 · build abcdef1", BuildInfo.label)
    end

    test "label shows version + 'dev build' when nothing but version resolves" do
      ENV["BUILD_VERSION"] = "1.2.3"
      BuildInfo.stubs(:git_sha).returns(nil)
      BuildInfo.stubs(:git_ref).returns(nil)

      assert_equal("v1.2.3 · dev build", BuildInfo.label)
    end

    test "blank ENV values are ignored in favour of git lookups" do
      ENV["BUILD_SHA"] = "   "
      BuildInfo.expects(:git_sha).returns("fromgit")

      assert_equal("fromgit", BuildInfo.sha)
    end
  end
end
