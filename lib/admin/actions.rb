# frozen_string_literal: true

require "auth/refresh_flow"

module Admin
  # Single home for every admin operation. Web controllers and Discord slash
  # command handlers both instantiate one of these and call the same methods,
  # so "reauth from the UI" and "/reauth in #commands" literally run the
  # identical code path. Zero behaviour duplication between entry points.
  #
  # Matrix clients are built per-call via `matrix_client_factory` so a
  # candidate token can be probed without touching the long-running sync
  # client's state. Injectable for testability.
  class Actions
    def initialize(matrix_client_factory:, refresh_flow: Auth::RefreshFlow.new)
      @matrix_client_factory = matrix_client_factory
      @refresh_flow = refresh_flow
    end

    def reauth(access_token:)
      probe = @matrix_client_factory.call(access_token)
      whoami = probe.whoami # raises Matrix::TokenError if the token is bad
      user_id = whoami.fetch("user_id")

      AuthState.update_token!(access_token: access_token, user_id: user_id)
      :ok
    end

    def resync
      SyncCheckpoint.reset!
      :ok
    end

    # Persists the Reddit cookie jar AND uses it to mint a fresh Matrix JWT
    # in one call, probing whoami before saving anything. Successful run
    # leaves AuthState with:
    #   - the fresh access_token
    #   - the user_id from whoami
    #   - the cookies encrypted at rest
    #   - reddit_session_expires_at populated
    # so the supervisor's refresh tick has everything it needs to keep the
    # Matrix token renewed indefinitely.
    def set_reddit_cookies!(cookie_jar)
      raise(ArgumentError, "cookie jar is blank") if cookie_jar.to_s.strip.empty?

      result = @refresh_flow.refresh_now(cookie_jar: cookie_jar)
      probe = @matrix_client_factory.call(result.access_token)
      user_id = probe.whoami.fetch("user_id")

      AuthState.store_reddit_session!(cookie_jar)
      AuthState.update_token!(access_token: result.access_token, user_id: user_id)
      :ok
    end

    def refresh_matrix_token!
      cookie_jar = AuthState.reddit_cookie_jar
      raise(Auth::RefreshFlow::RefreshError, "no stored Reddit cookies — visit /auth first") if cookie_jar.nil?

      result = @refresh_flow.refresh_now(cookie_jar: cookie_jar)
      AuthState.update_token!(access_token: result.access_token, user_id: AuthState.user_id)
      result
    end
  end
end
