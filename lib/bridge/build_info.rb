# frozen_string_literal: true

module Bridge
  # Resolves the build identity (commit SHA + ref) that the running image
  # was built from. The CI pipeline bakes these in as ENV at image build
  # time (see .github/workflows/ci.yml + Dockerfile). Locally they're
  # filled in by shelling to `git` inside the checkout; if neither
  # source has anything useful the label falls back to "dev build".
  module BuildInfo
    extend self

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
    def label
      sha = short_sha
      ref_name = ref

      if sha && ref_name
        "build #{sha} (#{ref_name})"
      elsif sha
        "build #{sha}"
      else
        "dev build"
      end
    end

    class << self
      private

      def env_value(name)
        value = ENV[name].to_s.strip
        value.empty? ? nil : value
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
