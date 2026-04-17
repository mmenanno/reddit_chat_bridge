# frozen_string_literal: true

require "matrix/client"
require "matrix/event_normalizer"
require "matrix/sync_loop"
require "discord/client"
require "discord/channel_index"
require "discord/poster"
require "discord/admin_notifier"
require "discord/logger"
require "admin/actions"
require "auth/refresh_flow"
require "bridge/supervisor"

module Bridge
  # Top-level service-graph assembly. Reads Discord + Matrix settings from
  # AppConfig, wires the client → normalizer → sync-loop → supervisor chain,
  # and exposes start!/stop! for the container entrypoint.
  #
  # `configured?` is the guard the web app uses to decide whether to spin
  # up the background thread at boot. If the admin hasn't finished /setup
  # yet, the web UI is still live but the sync loop stays dormant.
  class Application
    REQUIRED_CONFIG_KEYS = [
      "matrix_homeserver",
      "matrix_user_id",
      "discord_bot_token",
      "discord_guild_id",
      "discord_dms_category_id",
      "discord_admin_status_channel_id",
      "discord_admin_logs_channel_id",
    ].freeze

    attr_reader :matrix_client, :sync_loop, :supervisor, :poster, :admin_notifier, :logger, :admin_actions

    @mutex = Mutex.new

    class << self
      attr_reader :instance

      def configured?
        return false unless AuthState.access_token.to_s.strip != ""

        REQUIRED_CONFIG_KEYS.all? { |key| AppConfig.fetch(key, "").to_s.strip != "" }
      end

      def build
        new
      end

      def running?
        instance&.running? || false
      end

      # Idempotent entry point used by:
      #   - config.ru at container boot
      #   - the /settings and /auth controllers after a successful save,
      #     so the sync loop starts the moment the last piece of config
      #     lands without making the operator restart the container.
      # The singleton @instance is guarded by @mutex — the ThreadSafety cop
      # can't see that statically, so disable it for the supervised region.
      # rubocop:disable ThreadSafety/ClassInstanceVariable
      def start_if_configured!
        return instance if running?
        return unless configured?

        @mutex.synchronize do
          return @instance if @instance&.running?

          @instance = build
          @instance.start!
        end
        @instance
      end

      def shutdown!
        @mutex.synchronize do
          @instance&.stop!
          @instance = nil
        end
      end
      # rubocop:enable ThreadSafety/ClassInstanceVariable
    end

    def initialize
      @matrix_client = build_matrix_client
      @discord_client = build_discord_client
      @admin_notifier = build_admin_notifier
      @logger = build_logger
      @poster = build_poster
      @sync_loop = build_sync_loop
      @admin_actions = build_admin_actions
      @supervisor = build_supervisor
    end

    def start!
      @stopped = false
      @thread = Thread.new do # rubocop:disable ThreadSafety/NewThread
        Thread.current.name = "reddit_chat_bridge-supervisor"
        @supervisor.run_forever(stop_signal: -> { @stopped })
      end
      @thread
    end

    def stop!
      @stopped = true
      @thread&.join(30)
    end

    def running?
      @thread&.alive? || false
    end

    private

    def build_matrix_client
      Matrix::Client.new(
        access_token: -> { AuthState.access_token },
        homeserver: AppConfig.fetch("matrix_homeserver", Matrix::Client::DEFAULT_HOMESERVER),
      )
    end

    def build_discord_client
      Discord::Client.new(bot_token: AppConfig.fetch("discord_bot_token"))
    end

    def build_admin_notifier
      Discord::AdminNotifier.new(
        client: @discord_client,
        status_channel_id: AppConfig.fetch("discord_admin_status_channel_id"),
      )
    end

    def build_logger
      Discord::Logger.new(
        client: @discord_client,
        logs_channel_id: AppConfig.fetch("discord_admin_logs_channel_id"),
      )
    end

    def build_poster
      channel_index = Discord::ChannelIndex.new(
        client: @discord_client,
        guild_id: AppConfig.fetch("discord_guild_id"),
        category_id: AppConfig.fetch("discord_dms_category_id"),
      )
      Discord::Poster.new(
        client: @discord_client,
        channel_index: channel_index,
        matrix_client: @matrix_client,
        logger: @logger,
      )
    end

    def build_sync_loop
      Matrix::SyncLoop.new(
        client: @matrix_client,
        normalizer: Matrix::EventNormalizer.new(own_user_id: AppConfig.fetch("matrix_user_id")),
        dispatcher: @poster,
      )
    end

    def build_admin_actions
      matrix_homeserver = AppConfig.fetch("matrix_homeserver", Matrix::Client::DEFAULT_HOMESERVER)
      factory = ->(token) { Matrix::Client.new(access_token: token, homeserver: matrix_homeserver) }
      Admin::Actions.new(matrix_client_factory: factory)
    end

    def build_supervisor
      Supervisor.new(
        sync_loop: @sync_loop,
        admin_notifier: @admin_notifier,
        admin_actions: @admin_actions,
      )
    end
  end
end
