# frozen_string_literal: true

require "sinatra/base"
require "securerandom"
require "matrix/client"
require "admin/actions"

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
          Admin::Actions.new(matrix_client_factory: factory)
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
      end

      before do
        pass if request.path_info == "/health"
        pass if request.path_info.start_with?("/setup")
        pass if request.path_info == "/login"
        pass if request.path_info == "/logout"
        pass if request.path_info.end_with?(".css", ".js", ".ico", ".png", ".svg")

        return redirect("/setup") if AdminUser.first_run?
        return redirect("/login") unless logged_in?
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

      get "/actions" do
        erb(:actions)
      end

      post "/actions/resync" do
        admin_actions.resync
        @notice = "Sync checkpoint cleared. The next iteration will pull recent history."
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
