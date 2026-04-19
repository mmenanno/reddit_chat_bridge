# frozen_string_literal: true

module Bridge
  # Resolves the build identity (semantic version + commit SHA + ref) that
  # the running image was built from. The CI pipeline bakes these in as
  # ENV at image build time (see .github/workflows/ci.yml + Dockerfile).
  # Locally they're filled in by reading the VERSION file + shelling to
  # `git` inside the checkout; if nothing resolves the label falls back
  # to "dev build".
  module BuildInfo
    extend self

    UNKNOWN_VERSION = "0.0.0"

    def version
      env_value("BUILD_VERSION") || version_file || UNKNOWN_VERSION
    end

    def sha
      env_value("BUILD_SHA") || git_sha
    end

    def short_sha
      s = sha
      return unless s

      s.length > 7 ? s[0, 7] : s
    end

    def ref
      env_value("BUILD_REF") || git_ref
    end

    # One-line human-readable label for logs + Discord notices.
    # Since VERSION is bumped on every push (enforced by the pre-push
    # hook), the version alone uniquely identifies the build — the
    # commit SHA would be redundant noise.
    def label
      "v#{version}"
    end

    class << self
      private

      def env_value(name)
        value = ENV[name].to_s.strip
        value.empty? ? nil : value
      end

      def version_file
        File.read(File.join(repo_root, "VERSION")).strip.presence
      rescue Errno::ENOENT
        nil
      end

      def git_sha
        read_git("rev-parse", "HEAD")&.slice(0, 7)
      end

      def git_ref
        read_git("rev-parse", "--abbrev-ref", "HEAD")
      end

      def read_git(*)
        require "open3"
        stdout, status = Open3.capture2("git", *, chdir: repo_root)
        return unless status.success?

        value = stdout.strip
        value.empty? ? nil : value
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      end

      def repo_root
        File.expand_path("../..", __dir__)
      end
    end
  end
end
