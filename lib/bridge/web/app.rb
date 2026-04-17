# frozen_string_literal: true

require "sinatra/base"
require "securerandom"

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

      configure do
        set :views, VIEWS_ROOT
        set :public_folder, PUBLIC_ROOT
        set :show_exceptions, false
        set :raise_errors, true
        enable :sessions
        set :session_secret, (ENV["SESSION_SECRET"] || SecureRandom.hex(32))
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
      end

      before do
        pass if request.path_info == "/health"
        pass if request.path_info.start_with?("/setup")
        pass if request.path_info == "/login"
        pass if request.path_info == "/logout"
        pass if request.path_info.start_with?("/assets")

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

      BOOT_AT = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
