# frozen_string_literal: true

require "matrix/client"
require "matrix/event_normalizer"
require "matrix/invite_handler"
require "matrix/media_resolver"
require "matrix/sync_loop"
require "dedup/sent_registry"
require "discord/client"
require "discord/channel_index"
require "discord/channel_reorderer"
require "discord/gateway"
require "discord/outbound_dispatcher"
require "discord/poster"
require "discord/admin_notifier"
require "discord/logger"
require "discord/interaction_handler"
require "discord/message_request_notifier"
require "discord/message_component_router"
require "discord/slash_command_router"
require "reddit/profile_client"
require "admin/actions"
require "auth/refresh_flow"
require "bridge/build_info"
require "bridge/journal"
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

    attr_reader :matrix_client, :sync_loop, :supervisor, :poster, :admin_notifier, :logger, :admin_actions, :journal, :gateway

    @mutex = Mutex.new

    class << self
      attr_reader :instance

      def configured?
        return false unless AuthState.access_token.to_s.strip != ""

        values = AppConfig.fetch_many(REQUIRED_CONFIG_KEYS)
        REQUIRED_CONFIG_KEYS.all? { |key| values[key].to_s.strip != "" }
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
      @journal = Bridge::Journal.new(admin_notifier: @admin_notifier, logger: @logger)
      @sent_registry = Dedup::SentRegistry.new
      @outbound_dispatcher = build_outbound_dispatcher
      @poster = build_poster
      @sync_loop = build_sync_loop
      @admin_actions = build_admin_actions
      @supervisor = build_supervisor
      @gateway = build_gateway
    end

    def start!
      @stopped = false
      # The supervisor thread runs for the container's entire lifetime,
      # cooperatively stopping via @stopped / the signal handler. A
      # thread pool would be wrong here (pools are for short-lived
      # tasks), and Concurrent::TimerTask doesn't fit a blocking
      # `run_forever` — so a named Thread is the clearest primitive.
      # rubocop:disable ThreadSafety/NewThread
      @supervisor_thread = Thread.new do
        Thread.current.name = "reddit_chat_bridge-supervisor"
        @supervisor.run_forever(stop_signal: -> { @stopped })
      end
      # rubocop:enable ThreadSafety/NewThread
      start_gateway_thread_if_configured
      announce_online
      @supervisor_thread
    end

    def stop!
      @stopped = true
      @gateway&.stop!
      @gateway_thread&.join(10)
      @supervisor_thread&.join(30)
    end

    def running?
      @supervisor_thread&.alive? || false
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
      Discord::Poster.new(
        client: @discord_client,
        channel_index: build_channel_index,
        matrix_client: @matrix_client,
        logger: @logger,
        sent_registry: @sent_registry,
        reddit_profile_client: Reddit::ProfileClient.new,
        channel_reorderer: build_channel_reorderer,
      )
    end

    def build_outbound_dispatcher
      operator_ids = AppConfig.fetch("discord_operator_user_ids", "").to_s.split(/[,\s]+/)
      homeserver = AppConfig.fetch("matrix_homeserver", Matrix::Client::DEFAULT_HOMESERVER)
      Discord::OutboundDispatcher.new(
        matrix_client: @matrix_client,
        discord_client: @discord_client,
        channel_index: build_channel_index,
        media_resolver: Matrix::MediaResolver.new(homeserver: homeserver),
        reddit_profile_client: Reddit::ProfileClient.new,
        channel_reorderer: build_channel_reorderer,
        operator_discord_ids: operator_ids,
        journal: @journal,
      )
    end

    def build_channel_index
      Discord::ChannelIndex.new(
        client: @discord_client,
        guild_id: AppConfig.fetch("discord_guild_id"),
        category_id: AppConfig.fetch("discord_dms_category_id"),
      )
    end

    def build_channel_reorderer
      Discord::ChannelReorderer.new(
        client: @discord_client,
        guild_id: AppConfig.fetch("discord_guild_id", ""),
        logger: @logger,
      )
    end

    def build_gateway
      bot_token = AppConfig.fetch("discord_bot_token", "")
      return if bot_token.empty?

      interaction_handler = build_interaction_handler
      Discord::Gateway.new(
        bot_token: bot_token,
        on_message_create: ->(msg) { @outbound_dispatcher.dispatch(msg) },
        on_interaction_create: ->(interaction) { interaction_handler.call(interaction) },
        journal: @journal,
      )
    end

    # Gateway-delivered interactions. When Discord's Interactions Endpoint
    # URL is blank (e.g. tailnet-only deployments), Discord ships every
    # interaction — slash commands AND button clicks — over the websocket
    # as INTERACTION_CREATE. The handler defers the ACK (types 5/6) so the
    # 3-second callback deadline is met even when the router does blocking
    # Matrix work, then edits @original via the interaction webhook once
    # the real response is ready.
    def build_interaction_handler
      Discord::InteractionHandler.new(
        client: @discord_client,
        slash_command_router: slash_command_router,
        message_component_router: message_component_router,
        journal: @journal,
      )
    end

    def slash_command_router
      Discord::SlashCommandRouter.new(
        admin_actions: @admin_actions,
        guild_id: AppConfig.fetch("discord_guild_id", ""),
        commands_channel_id: AppConfig.fetch("discord_admin_commands_channel_id", ""),
      )
    end

    def message_component_router
      Discord::MessageComponentRouter.new(
        admin_actions: @admin_actions,
        notifier: message_request_notifier,
      )
    end

    def message_request_notifier
      Discord::MessageRequestNotifier.new(
        client: @discord_client,
        channel_id: AppConfig.fetch("discord_message_requests_channel_id", ""),
        fallback_channel_id: AppConfig.fetch("discord_admin_status_channel_id", ""),
      )
    end

    # One-shot "the bridge is alive" notice the moment start! returns.
    # Goes through the journal so it shows up both in the in-app event
    # log and #app-logs on Discord. Fired once per process because
    # start_if_configured! is mutex-guarded against re-entry.
    def announce_online
      user_id = AuthState.user_id.to_s.presence || "no token yet"
      gateway_status = @gateway_thread&.alive? ? "up" : "disabled"
      @journal&.info(
        "Bridge online · #{Bridge::BuildInfo.label} · matrix user #{user_id} · discord gateway #{gateway_status}",
        source: "application",
      )
    end

    def start_gateway_thread_if_configured
      return unless @gateway

      # Long-lived websocket worker, same reasoning as the supervisor
      # thread — a pool would be inappropriate for a connection that
      # blocks forever.
      # rubocop:disable ThreadSafety/NewThread
      @gateway_thread = Thread.new do
        Thread.current.name = "reddit_chat_bridge-discord-gateway"
        @gateway.run(stop_signal: -> { @stopped })
      end
      # rubocop:enable ThreadSafety/NewThread
    end

    def build_sync_loop
      homeserver = AppConfig.fetch("matrix_homeserver", Matrix::Client::DEFAULT_HOMESERVER)
      media_resolver = Matrix::MediaResolver.new(homeserver: homeserver)
      Matrix::SyncLoop.new(
        client: @matrix_client,
        normalizer: Matrix::EventNormalizer.new(
          own_user_id: AppConfig.fetch("matrix_user_id"),
          media_resolver: media_resolver,
        ),
        dispatcher: @poster,
        invite_handler: Matrix::InviteHandler.new(
          own_user_id: AppConfig.fetch("matrix_user_id"),
          notifier: message_request_notifier,
          media_resolver: media_resolver,
        ),
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
        journal: @journal,
      )
    end
  end
end
