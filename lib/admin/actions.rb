# frozen_string_literal: true

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
    def initialize(matrix_client_factory:)
      @matrix_client_factory = matrix_client_factory
    end

    def reauth(access_token:, user_id:)
      probe = @matrix_client_factory.call(access_token)
      probe.whoami # raises Matrix::TokenError if the token is bad

      AuthState.update_token!(access_token: access_token, user_id: user_id)
      :ok
    end

    def resync
      SyncCheckpoint.reset!
      :ok
    end
  end
end
