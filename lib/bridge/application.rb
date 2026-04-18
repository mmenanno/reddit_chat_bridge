# frozen_string_literal: true

require "matrix/client"
require "matrix/event_normalizer"
require "matrix/invite_handler"
require "matrix/media_resolver"
require "matrix/sync_loop"
require "dedup/sent_registry"
require "discord/client"
require "discord/channel_index"
require "discord/gateway"
require "discord/outbound_dispatcher"
require "discord/poster"
require "discord/admin_notifier"
require "discord/logger"
require "discord/message_request_notifier"
require "discord/message_component_router"
require "discord/slash_command_router"
require "reddit/profile_client"
require "admin/actions"
require "auth/refresh_flow"
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
      @supervisor_thread = Thread.new do # rubocop:disable ThreadSafety/NewThread
        Thread.current.name = "reddit_chat_bridge-supervisor"
        @supervisor.run_forever(stop_signal: -> { @stopped })
      end
      start_gateway_thread_if_configured
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
        sent_registry: @sent_registry,
        reddit_profile_client: Reddit::ProfileClient.new,
      )
    end

    def build_outbound_dispatcher
      operator_ids = AppConfig.fetch("discord_operator_user_ids", "").to_s.split(/[,\s]+/)
      Discord::OutboundDispatcher.new(
        matrix_client: @matrix_client,
        operator_discord_ids: operator_ids,
        journal: @journal,
      )
    end

    def build_gateway
      bot_token = AppConfig.fetch("discord_bot_token", "")
      return if bot_token.empty?

      Discord::Gateway.new(
        bot_token: bot_token,
        on_message_create: ->(msg) { @outbound_dispatcher.dispatch(msg) },
        on_interaction_create: ->(interaction) { handle_gateway_interaction(interaction) },
        journal: @journal,
      )
    end

    # Gateway-delivered interactions. When Discord's Interactions Endpoint
    # URL is blank (e.g. tailnet-only deployments), Discord ships every
    # interaction — slash commands AND button clicks — over the websocket
    # as INTERACTION_CREATE. We branch on payload.type to pick the right
    # router and reply via the REST callback endpoint within 3 seconds.
    def handle_gateway_interaction(payload)
      type = payload["type"]
      @journal&.info("Interaction received: #{interaction_label(payload)}", source: "gateway")

      response = route_interaction(payload, type)
      return unless response

      @discord_client.create_interaction_response(
        interaction_id: payload["id"],
        interaction_token: payload["token"],
        payload: response,
      )
      @journal&.info("Interaction answered: #{interaction_label(payload)}", source: "gateway")
    rescue StandardError => e
      @journal&.warn(
        "Gateway interaction callback failed: #{e.class}: #{e.message}",
        source: "gateway",
      )
    end

    def route_interaction(payload, type)
      case type
      when 1, 2 then slash_command_router.dispatch(payload)
      when 3 then message_component_router.dispatch(payload)
      end
    end

    def interaction_label(payload)
      case payload["type"]
      when 1 then "PING"
      when 2 then "/#{payload.dig("data", "name")}"
      when 3 then "button #{payload.dig("data", "custom_id")}"
      else "(type=#{payload["type"]})"
      end
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

    def start_gateway_thread_if_configured
      return unless @gateway

      @gateway_thread = Thread.new do # rubocop:disable ThreadSafety/NewThread
        Thread.current.name = "reddit_chat_bridge-discord-gateway"
        @gateway.run(stop_signal: -> { @stopped })
      end
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
