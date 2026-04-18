# frozen_string_literal: true

require "sinatra/base"
require "securerandom"
require "matrix/client"
require "matrix/event_normalizer"
require "matrix/media_resolver"
require "discord/client"
require "discord/channel_index"
require "discord/interaction_verifier"
require "discord/poster"
require "discord/message_request_notifier"
require "discord/slash_command_router"
require "reddit/profile_client"
require "admin/actions"
require "admin/reconciler"

module Bridge
  module Web
    # The bridge's web surface. Sinatra::Base subclass so the app can be
    # mounted, tested with Rack::Test, and booted through any Rack server.
    #
    # Routes in this class are the setup/auth/dashboard spine; the richer
    # admin and config surfaces (rooms, settings, auth-token, actions)
    # land in later slices.
    #
    # Auth model: one-session cookie, bcrypted AdminUser passwords. With
    # no admin users in the database, every request force-routes to
    # `/setup` until the first admin is created.
    class App < Sinatra::Base
      VIEWS_ROOT  = File.expand_path("../../../app/views", __dir__)
      PUBLIC_ROOT = File.expand_path("../../../app/assets/built", __dir__)

      # This block runs at class-load time and reads AppConfig for the
      # persisted session_secret. Callers must have run `Bridge::Boot.call`
      # before requiring this file — otherwise the model constants aren't
      # loaded yet. config.ru and test_helper both enforce that order.
      configure do
        set :views, VIEWS_ROOT
        set :public_folder, PUBLIC_ROOT
        set :show_exceptions, false
        set :raise_errors, true
        enable :sessions
        set :session_secret, (
          ENV["SESSION_SECRET"] ||
          AppConfig.get("session_secret") ||
          SecureRandom.hex(32).tap { |s| AppConfig.set("session_secret", s) }
        )
      end

      configure :test do
        # Rack::Protection blocks rack-test requests by default (no Origin,
        # Host mismatch, etc.). Production keeps the middleware on; tests
        # exercise the app directly.
        disable :protection
      end

      helpers do
        def current_user
          return unless session[:admin_user_id]

          @current_user ||= AdminUser.find_by(id: session[:admin_user_id])
        end

        def logged_in?
          !current_user.nil?
        end

        def login!(user)
          session[:admin_user_id] = user.id
        end

        def logout!
          session.delete(:admin_user_id)
          @current_user = nil
        end

        def admin_actions
          factory = lambda { |token|
            homeserver = AppConfig.fetch("matrix_homeserver", Matrix::Client::DEFAULT_HOMESERVER)
            Matrix::Client.new(access_token: token, homeserver: homeserver)
          }
          actions = Admin::Actions.new(matrix_client_factory: factory, reconciler: build_reconciler)
          actions.message_request_web_notifier = build_message_request_notifier
          actions
        end

        def build_message_request_notifier
          return unless Bridge::Application.configured?

          client = Discord::Client.new(bot_token: AppConfig.fetch("discord_bot_token"))
          Discord::MessageRequestNotifier.new(
            client: client,
            channel_id: AppConfig.fetch("discord_message_requests_channel_id", ""),
            fallback_channel_id: AppConfig.fetch("discord_admin_status_channel_id", ""),
          )
        end

        # Returns a Reconciler wired from live config, or nil when Discord +
        # Matrix config isn't fully populated yet (reconcile isn't reachable
        # from the UI in that state anyway — actions page sits behind the
        # setup wizard / settings).
        def build_reconciler
          return unless Bridge::Application.configured?

          homeserver = AppConfig.fetch("matrix_homeserver", Matrix::Client::DEFAULT_HOMESERVER)
          matrix_client = Matrix::Client.new(
            access_token: -> { AuthState.access_token },
            homeserver: homeserver,
          )
          discord_client = Discord::Client.new(bot_token: AppConfig.fetch("discord_bot_token"))
          channel_index = Discord::ChannelIndex.new(
            client: discord_client,
            guild_id: AppConfig.fetch("discord_guild_id"),
            category_id: AppConfig.fetch("discord_dms_category_id"),
          )
          poster = Discord::Poster.new(
            client: discord_client,
            channel_index: channel_index,
            matrix_client: matrix_client,
            reddit_profile_client: Reddit::ProfileClient.new,
          )
          normalizer = Matrix::EventNormalizer.new(own_user_id: AppConfig.fetch("matrix_user_id"))
          Admin::Reconciler.new(
            matrix_client: matrix_client,
            discord_client: discord_client,
            channel_index: channel_index,
            poster: poster,
            normalizer: normalizer,
          )
        end

        def settings_fields_with_values
          App::SETTINGS_FIELDS.map do |field|
            stored = AppConfig.get(field[:key])
            # Pre-fill with the default when the admin hasn't saved a value yet,
            # so hints like "should be https://matrix.redditspace.com" aren't
            # just decoration — the field actually arrives that way.
            value = stored.nil? || stored.empty? ? field[:default] : stored
            field.merge(value: value)
          end
        end

        # Marks a nav link as the current page. Dashboard is special-cased
        # because its path is "/" which would otherwise match every prefix.
        def current_nav?(href)
          return request.path_info == "/" if href == "/"

          request.path_info.start_with?(href)
        end

        # Live sync status for the header pill + dashboard hero. Returns
        # { label:, tone: } where tone feeds the `.status-pill--<tone>` class.
        def dashboard_sync_status
          if AuthState.paused?
            { label: "Paused", tone: "danger" }
          elsif Bridge::Application.running?
            { label: "Live", tone: "healthy" }
          elsif Bridge::Application.configured?
            { label: "Stopped", tone: "warning" }
          else
            { label: "Unconfigured", tone: "idle" }
          end
        end

        # Absolute → "5m ago" style for activity/status timestamps. Falls back
        # to the ISO-8601 UTC string when the delta is long enough that a
        # relative label becomes useless.
        def time_ago(time)
          return "—" if time.nil?

          delta = (Time.current - time).to_i
          return "just now" if delta < 10
          return "#{delta}s ago" if delta < 60
          return "#{delta / 60}m ago" if delta < 3600
          return "#{delta / 3600}h ago" if delta < 86_400

          time.utc.strftime("%Y-%m-%d")
        end

        # Friendly label for a Room in status banners — prefers the resolved
        # counterparty username, then the counterparty's matrix id localpart,
        # and falls back to the opaque matrix_room_id only when nothing
        # human-readable is cached yet.
        def room_display_name(room)
          return room.counterparty_username if room.counterparty_username.present?
          return matrix_id_localpart(room.counterparty_matrix_id) if room.counterparty_matrix_id.present?

          room.matrix_room_id
        end

        def matrix_id_localpart(matrix_id)
          matrix_id.to_s.sub(/\A@/, "").sub(/:.+\z/, "")
        end

        # Matrix ships `origin_server_ts` in milliseconds-since-epoch. These
        # two helpers turn that into the labels the transcript view uses for
        # its day dividers and per-bubble timestamps.
        def transcript_day_label(ts_ms)
          return unless ts_ms

          event_time = Time.at(ts_ms.to_i / 1000.0).in_time_zone
          days_ago = ((Time.current.beginning_of_day - event_time.beginning_of_day) / 86_400).to_i
          return "Today" if days_ago.zero?
          return "Yesterday" if days_ago == 1
          return event_time.strftime("%A") if days_ago < 7

          event_time.strftime("%B %-d, %Y")
        end

        def transcript_time_label(ts_ms)
          return unless ts_ms

          Time.at(ts_ms.to_i / 1000.0).in_time_zone.strftime("%-l:%M %p")
        end

        # Deciding whether a message needs a sender-header (avatar + name +
        # time) or whether it can ride as a continuation bubble under the
        # previous message. Matches iMessage/Discord intuition: same sender,
        # same day, within a short gap → group.
        def transcript_new_group?(event, previous)
          return true if previous.nil?
          return true if event.sender != previous.sender
          return true if (event.origin_server_ts.to_i - previous.origin_server_ts.to_i) > 5 * 60 * 1000

          false
        end

        def transcript_new_day?(event, previous)
          return true if previous.nil?

          transcript_day_of(event.origin_server_ts) != transcript_day_of(previous.origin_server_ts)
        end

        def transcript_day_of(ts_ms)
          Time.at(ts_ms.to_i / 1000.0).in_time_zone.to_date
        end

        # Shared handler body for /requests/:id/approve and /:id/decline —
        # both routes have identical shape modulo the method name.
        def handle_message_request_action(method_name, id)
          request = MessageRequest.find_by(id: id)
          verb = method_name == :approve_message_request! ? "Approve" : "Decline"

          if request.nil?
            @error = "Message request not found."
          else
            begin
              admin_actions.public_send(method_name, id: request.id)
              @notice = "#{verb}d message request from #{request.display_name}."
            rescue Matrix::Error, Discord::Error => e
              @error = "#{verb} failed: #{e.class}: #{e.message}"
            end
          end

          @pending = MessageRequest.pending.to_a
          @resolved = MessageRequest.recent_resolved.limit(20).to_a
          erb(:requests)
        end
      end

      before do
        pass if request.path_info == "/health"
        pass if request.path_info.start_with?("/setup")
        pass if request.path_info == "/login"
        pass if request.path_info == "/logout"
        pass if request.path_info == "/discord/interactions"
        pass if request.path_info.end_with?(".css", ".js", ".ico", ".png", ".svg")

        return redirect("/setup") if AdminUser.first_run?
        return redirect("/login") unless logged_in?
      end

      # Discord calls this when someone invokes a registered slash command
      # in #commands. Must verify the Ed25519 signature on every request
      # — Discord routinely tests an endpoint by sending invalid payloads
      # and will deregister the URL if we ever return 2xx for a bad one.
      post "/discord/interactions" do
        raw = request.body.read || ""
        request.body.rewind

        verifier = Discord::InteractionVerifier.new(
          public_key_hex: AppConfig.fetch("discord_public_key", ""),
        )

        unless verifier.valid?(
          signature_hex: request.env["HTTP_X_SIGNATURE_ED25519"],
          timestamp: request.env["HTTP_X_SIGNATURE_TIMESTAMP"],
          body: raw,
        )
          halt 401, "invalid signature"
        end

        payload = JSON.parse(raw)
        router = Discord::SlashCommandRouter.new(
          admin_actions: admin_actions,
          guild_id: AppConfig.fetch("discord_guild_id", ""),
          commands_channel_id: AppConfig.fetch("discord_admin_commands_channel_id", ""),
        )

        response = router.dispatch(payload)
        content_type :json
        JSON.generate(response)
      end

      get "/health" do
        content_type :json
        {
          status: "ok",
          uptime_s: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - App::BOOT_AT).to_i,
          matrix: AuthState.paused? ? "paused" : "ok",
        }.to_json
      end

      get "/setup" do
        redirect("/") unless AdminUser.first_run?

        erb(:setup)
      end

      post "/setup" do
        redirect("/") unless AdminUser.first_run?

        username = params[:username].to_s.strip
        password = params[:password].to_s

        begin
          user = AdminUser.create_with_password!(username: username, password: password)
          login!(user)
          redirect("/")
        rescue ActiveRecord::RecordInvalid => e
          @error = e.message
          erb(:setup)
        end
      end

      get "/login" do
        redirect("/setup") if AdminUser.first_run?
        redirect("/") if logged_in?

        erb(:login)
      end

      post "/login" do
        user = AdminUser.authenticate(username: params[:username].to_s, password: params[:password].to_s)

        if user
          login!(user)
          redirect("/")
        else
          @error = "Invalid username or password."
          erb(:login)
        end
      end

      post "/logout" do
        logout!
        redirect("/login")
      end

      get "/" do
        erb(:dashboard)
      end

      # Ordered list of keys the /settings form manages, along with a friendly
      # label and a hint shown under the input. These live in the DB via
      # AppConfig; the Matrix access token itself is handled separately in
      # /auth because its persistence goes through AuthState + a probe.
      SETTINGS_FIELDS = [
        {
          key: "matrix_homeserver",
          label: "Matrix homeserver URL",
          hint: "Reddit's chat homeserver. Should be https://matrix.redditspace.com unless Reddit migrates.",
          default: "https://matrix.redditspace.com",
          secret: false,
        },
        {
          key: "matrix_user_id",
          label: "Matrix user ID",
          hint: "Looks like @t2_<opaque>:reddit.com. Find it in DevTools → any /_matrix/client/v3/account/whoami response.",
          default: "",
          secret: false,
        },
        {
          key: "discord_bot_token",
          label: "Discord bot token",
          hint: "From the Discord Developer Portal → your app → Bot → Reset Token.",
          default: "",
          secret: true,
        },
        {
          key: "discord_guild_id",
          label: "Discord server (guild) ID",
          hint: "Right-click the server in Discord (with Developer Mode on) → Copy Server ID.",
          default: "",
          secret: false,
        },
        {
          key: "discord_dms_category_id",
          label: "Reddit DMs category ID",
          hint: "The category where #dm-* channels will be auto-created.",
          default: "",
          secret: false,
        },
        {
          key: "discord_admin_status_channel_id",
          label: "#app-status channel ID",
          hint: "Where critical alerts land. @everyone pinged on fatal errors only.",
          default: "",
          secret: false,
        },
        {
          key: "discord_admin_logs_channel_id",
          label: "#app-logs channel ID",
          hint: "Info/warn lines from the bridge's operational log.",
          default: "",
          secret: false,
        },
        {
          key: "discord_admin_commands_channel_id",
          label: "#commands channel ID",
          hint: "Slash-command surface. Restrict to @BotAdmin.",
          default: "",
          secret: false,
        },
        {
          key: "discord_message_requests_channel_id",
          label: "#message-requests channel ID",
          hint: "Incoming Reddit message requests post here with Approve/Decline buttons. Falls back to #app-status if blank.",
          default: "",
          secret: false,
        },
        {
          key: "discord_application_id",
          label: "Discord application ID",
          hint: "Developer Portal → your app → General Information → Application ID.",
          default: "",
          secret: false,
        },
        {
          key: "discord_public_key",
          label: "Discord application public key",
          hint: "Only needed if you're exposing /discord/interactions publicly. Tailnet-only deployments can leave this blank — the bot delivers slash commands over its gateway websocket instead.",
          default: "",
          secret: false,
        },
        {
          key: "discord_operator_user_ids",
          label: "Operator Discord user IDs",
          hint: "Comma- or space-separated list. Only messages typed by these users in a dm-* channel get relayed back to Reddit. Leave empty to accept any non-bot author (single-user deployments).",
          default: "",
          secret: false,
        },
      ].freeze

      get "/settings" do
        @fields = settings_fields_with_values
        erb(:settings)
      end

      post "/settings" do
        SETTINGS_FIELDS.each do |field|
          submitted = params[field[:key]].to_s.strip
          AppConfig.set(field[:key], submitted)
        end

        was_running = Bridge::Application.running?
        Bridge::Application.start_if_configured!
        @notice = if !was_running && Bridge::Application.running?
          "Settings saved. Sync is now running."
        else
          "Settings saved."
        end
        @fields = settings_fields_with_values
        erb(:settings)
      end

      get "/rooms" do
        @rooms = Room.order(:counterparty_username).to_a
        erb(:rooms)
      end

      # Live-fetch transcript for a single bridged room. Pulls the last ~60
      # events from Reddit's Matrix server on each load — we don't cache
      # message bodies locally, so if the token is paused the transcript
      # surfaces an auth banner instead of a stale snapshot.
      get "/rooms/:id" do
        @room = Room.find_by(id: params[:id])
        halt(404, "Room not found") unless @room

        @from_token = params[:from].presence
        @events = []
        @older_token = nil
        @transcript_error = nil
        @auth_paused = AuthState.paused? || AuthState.access_token.to_s.strip.empty?

        if @auth_paused
          @transcript_error = "Matrix auth is paused or missing — paste a token on /auth to load this transcript."
        else
          begin
            homeserver = AppConfig.fetch("matrix_homeserver", Matrix::Client::DEFAULT_HOMESERVER)
            client = Matrix::Client.new(access_token: -> { AuthState.access_token }, homeserver: homeserver)
            raw = client.room_messages(room_id: @room.matrix_room_id, dir: "b", limit: 60, from: @from_token)
            # dir=b returns newest first; reverse for chronological display.
            chunk = (raw["chunk"] || []).reverse
            media_resolver = Matrix::MediaResolver.new(homeserver: homeserver)
            normalizer = Matrix::EventNormalizer.new(
              own_user_id: AppConfig.fetch("matrix_user_id"),
              media_resolver: media_resolver,
            )
            @events = normalizer.normalize_chunk(
              room_id: @room.matrix_room_id,
              chunk: chunk,
              state: raw["state"],
            )
            @older_token = raw["end"] if chunk.any?
          rescue Matrix::TokenError => e
            @auth_paused = true
            @transcript_error = "Matrix token rejected (#{e.message}) — refresh on /auth."
          rescue Matrix::Error => e
            @transcript_error = "Matrix /messages call failed: #{e.class}: #{e.message}"
          end
        end

        erb(:room_transcript)
      end

      get "/requests" do
        @pending = MessageRequest.pending.to_a
        @resolved = MessageRequest.recent_resolved.limit(20).to_a
        erb(:requests)
      end

      post "/requests/:id/approve" do
        handle_message_request_action(:approve_message_request!, params[:id])
      end

      post "/requests/:id/decline" do
        handle_message_request_action(:decline_message_request!, params[:id])
      end

      get "/events" do
        @entries = EventLogEntry.recent(limit: 500).to_a
        erb(:events)
      end

      post "/events/clear" do
        deleted = EventLogEntry.clear_all!
        @entries = []
        @notice = "Cleared #{deleted} log entr#{deleted == 1 ? "y" : "ies"}."
        erb(:events)
      end

      post "/rooms/:id/refresh" do
        room = Room.find_by(id: params[:id])

        if room.nil?
          @error = "Room not found."
        else
          begin
            result = admin_actions.refresh_room!(matrix_room_id: room.matrix_room_id)
            @notice = "Refreshed #{room_display_name(room)}: " \
                      "channel #{result[:renamed] ? "renamed" : "unchanged"}, " \
                      "#{result[:posted_attempted]} event(s) re-examined."
          rescue Admin::Actions::NotConfiguredError => e
            @error = e.message
          rescue Matrix::Error, Discord::Error => e
            @error = "Refresh failed: #{e.class}: #{e.message}"
          end
        end

        @rooms = Room.order(:counterparty_username).to_a
        erb(:rooms)
      end

      post "/rooms/:id/archive" do
        room = Room.find_by(id: params[:id])

        if room.nil?
          @error = "Room not found."
        else
          begin
            result = admin_actions.archive_room!(matrix_room_id: room.matrix_room_id)
            @notice = result == :already_archived ? "Room was already archived." : "Archived #{room_display_name(room)} — Discord channel deleted."
          rescue Admin::Actions::NotConfiguredError => e
            @error = e.message
          rescue Matrix::Error, Discord::Error => e
            @error = "Archive failed: #{e.class}: #{e.message}"
          end
        end

        @rooms = Room.order(:counterparty_username).to_a
        erb(:rooms)
      end

      post "/rooms/:id/end" do
        room = Room.find_by(id: params[:id])

        if room.nil?
          @error = "Room not found."
        else
          display = room_display_name(room)
          begin
            admin_actions.end_chat!(matrix_room_id: room.matrix_room_id)
            @notice = "Hid chat with #{display}. Future events in this room are filtered; click Restore on /rooms to re-bridge."
          rescue Admin::Actions::NotConfiguredError => e
            @error = e.message
          rescue Discord::Error => e
            @error = "End chat failed: #{e.class}: #{e.message}"
          end
        end

        @rooms = Room.order(:counterparty_username).to_a
        erb(:rooms)
      end

      post "/rooms/:id/restore" do
        room = Room.find_by(id: params[:id])

        if room.nil?
          @error = "Room not found."
        else
          begin
            admin_actions.restore_chat!(matrix_room_id: room.matrix_room_id)
            @notice = "Restored #{room_display_name(room)}. Next Reddit message in this room will create a fresh Discord channel."
          rescue Admin::Actions::NotConfiguredError => e
            @error = e.message
          end
        end

        @rooms = Room.order(:counterparty_username).to_a
        erb(:rooms)
      end

      post "/rooms/:id/unarchive" do
        room = Room.find_by(id: params[:id])
        backfill = params["backfill"] == "1"

        if room.nil?
          @error = "Room not found."
        else
          begin
            result = admin_actions.unarchive_room!(matrix_room_id: room.matrix_room_id, backfill: backfill)
            label = backfill ? "restored with #{result[:posted_attempted]} event(s) replayed" : "unarchived — channel will recreate on next message"
            @notice = "#{room_display_name(room)} #{label}."
          rescue Admin::Actions::NotConfiguredError => e
            @error = e.message
          rescue Matrix::Error, Discord::Error => e
            @error = "Unarchive failed: #{e.class}: #{e.message}"
          end
        end

        @rooms = Room.order(:counterparty_username).to_a
        erb(:rooms)
      end

      get "/actions" do
        erb(:actions)
      end

      post "/actions/resync" do
        admin_actions.resync
        @notice = "Sync checkpoint cleared. The next iteration will pull recent history."
        erb(:actions)
      end

      post "/actions/reconcile" do
        begin
          stats = admin_actions.reconcile_channels!
          @notice = "Reconcile complete: #{stats[:renamed]} renamed, " \
                    "#{stats[:skipped]} skipped, #{stats[:errors]} errors."
        rescue Admin::Actions::NotConfiguredError => e
          @error = e.message
        end
        erb(:actions)
      end

      post "/actions/test_discord" do
        begin
          admin_actions.test_discord!
          @notice = "Posted a probe message to #app-status. If you see it, Discord config is good."
        rescue Admin::Actions::NotConfiguredError => e
          @error = e.message
        rescue Discord::Error => e
          @error = "Discord probe failed: #{e.class}: #{e.message}"
        end
        erb(:actions)
      end

      post "/actions/rebuild_all" do
        begin
          stats = admin_actions.rebuild_all!
          @notice = "Rebuild: refreshed #{stats[:rebuilt]} room(s) (#{stats[:rebuild_errors]} errors). " \
                    "Channels are current; recent history replayed where needed."
        rescue Admin::Actions::NotConfiguredError => e
          @error = e.message
        end
        erb(:actions)
      end

      post "/actions/full_resync" do
        stats = admin_actions.full_resync!
        @notice = "Full resync: deleted #{stats[:channels_deleted]} Discord channel(s) " \
                  "(#{stats[:channel_delete_errors]} errors), cleared refs on #{stats[:rooms_reset]} room(s), " \
                  "wiped #{stats[:events_cleared]} posted-event record(s), reset the sync checkpoint, " \
                  "rebuilt #{stats[:rebuilt]} room(s) (#{stats[:rebuild_errors]} errors)."
        erb(:actions)
      end

      post "/actions/register_slash_commands" do
        begin
          app_id = AppConfig.fetch("discord_application_id", "")
          guild_id = AppConfig.fetch("discord_guild_id", "")
          if app_id.empty? || guild_id.empty?
            @error = "Set discord_application_id + discord_guild_id on /settings first."
          else
            client = Discord::Client.new(bot_token: AppConfig.fetch("discord_bot_token"))
            client.bulk_set_guild_commands(
              application_id: app_id,
              guild_id: guild_id,
              commands: Discord::SlashCommandRouter::COMMAND_DEFINITIONS,
            )
            @notice = "Registered #{Discord::SlashCommandRouter::COMMAND_DEFINITIONS.size} slash commands with Discord."
          end
        rescue Discord::Error => e
          @error = "Discord rejected the registration: #{e.class}: #{e.message}"
        end
        erb(:actions)
      end

      post "/actions/start_sync" do
        if Bridge::Application.running?
          @notice = "Sync is already running."
        elsif !Bridge::Application.configured?
          @error = "Can't start yet. Finish /settings and paste a token on /auth first."
        else
          Bridge::Application.start_if_configured!
          @notice = Bridge::Application.running? ? "Sync started." : "Failed to start sync — check the logs."
        end
        erb(:actions)
      end

      get "/auth" do
        erb(:auth)
      end

      post "/auth" do
        token = params[:access_token].to_s.strip.sub(/\ABearer\s+/i, "")

        if token.empty?
          @error = "Paste an access token before submitting."
          return erb(:auth)
        end

        begin
          admin_actions.reauth(access_token: token)
          was_running = Bridge::Application.running?
          Bridge::Application.start_if_configured!
          @notice = if !was_running && Bridge::Application.running?
            "Token probed and saved. Sync is now running."
          else
            "Token probed and saved. Matrix sync resumes on the next iteration."
          end
        rescue Matrix::TokenError => e
          @error = "Reddit rejected that token: #{e.message}"
        rescue Matrix::Error => e
          @error = "Couldn't reach Reddit: #{e.message}"
        end

        erb(:auth)
      end

      post "/auth/cookies" do
        cookie_jar = params[:reddit_cookie].to_s.strip

        if cookie_jar.empty?
          @error = "Paste your Reddit Cookie header before submitting."
          return erb(:auth)
        end

        begin
          admin_actions.set_reddit_cookies!(cookie_jar)
          was_running = Bridge::Application.running?
          Bridge::Application.start_if_configured!
          @notice = if !was_running && Bridge::Application.running?
            "Reddit cookies saved and fresh token minted. Sync is now running."
          else
            "Reddit cookies saved and fresh token minted. Future expirations refresh automatically."
          end
        rescue Auth::RefreshFlow::RefreshError => e
          @error = "Reddit rejected those cookies: #{e.message}"
        rescue Matrix::TokenError => e
          @error = "Reddit minted a JWT but Matrix rejected it: #{e.message}"
        rescue ArgumentError => e
          @error = e.message
        end

        erb(:auth)
      end

      BOOT_AT = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
