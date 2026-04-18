# frozen_string_literal: true

require "auth/refresh_flow"
require "admin/reconciler"

module Admin
  # Single home for every admin operation. Web controllers and Discord slash
  # command handlers both instantiate one of these and call the same methods,
  # so "reauth from the UI" and "/reauth in #commands" literally run the
  # identical code path. Zero behaviour duplication between entry points.
  #
  # Matrix clients are built per-call via `matrix_client_factory` so a
  # candidate token can be probed without touching the long-running sync
  # client's state. `reconciler` is optional — only the reconcile/refresh
  # operations need it, and building it requires full Discord+Matrix config,
  # which reauth/resync don't.
  class Actions
    class NotConfiguredError < StandardError; end

    def initialize(matrix_client_factory:, refresh_flow: Auth::RefreshFlow.new, reconciler: nil)
      @matrix_client_factory = matrix_client_factory
      @refresh_flow = refresh_flow
      @reconciler = reconciler
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

    # Destructive: wipes every Room's Discord channel/webhook + last_event_id,
    # deletes the entire PostedEvent dedup cache, and clears the /sync
    # checkpoint. Then — if a reconciler is wired — immediately iterates
    # every room, recreates its channel + webhook, and backfills recent
    # history so the operator doesn't have to wait for the next Reddit
    # message to see the rebuild take effect. Room rows themselves are
    # kept so counterparty_username survives; new channels get the right
    # names immediately.
    def full_resync!
      clear_stats = nuke_persisted_state!
      rebuild_stats = rebuild_all_rooms!
      clear_stats.merge(rebuild_stats)
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

    def reconcile_channels!
      require_reconciler!
      @reconciler.reconcile_all
    end

    def refresh_room!(matrix_room_id:)
      require_reconciler!
      @reconciler.refresh_one(matrix_room_id: matrix_room_id)
    end

    # Non-destructive counterpart of full_resync!: iterates every room and
    # runs it through refresh_one (rename + backfill), but doesn't touch
    # the PostedEvent cache or sync checkpoint. Use after fixing a Discord
    # permissions issue or to catch up history without losing dedup state.
    def rebuild_all!
      require_reconciler!
      rebuild_all_rooms!
    end

    def archive_room!(matrix_room_id:)
      require_reconciler!
      @reconciler.archive!(matrix_room_id: matrix_room_id)
    end

    def unarchive_room!(matrix_room_id:, backfill: false)
      require_reconciler!
      @reconciler.unarchive!(matrix_room_id: matrix_room_id, backfill: backfill)
    end

    private

    def nuke_persisted_state!
      rooms_reset = 0
      events_cleared = 0
      ActiveRecord::Base.transaction do
        rooms_reset = Room.update_all(
          discord_channel_id: nil,
          discord_webhook_id: nil,
          discord_webhook_token: nil,
          last_event_id: nil,
        )
        events_cleared = PostedEvent.delete_all
        SyncCheckpoint.reset!
      end
      { rooms_reset: rooms_reset, events_cleared: events_cleared }
    end

    # Per-room rescue: one flaky Matrix/Discord call shouldn't abort the
    # whole rebuild. The refresh_one call itself is idempotent — PostedEvent
    # dedup keeps replay safe if the operator re-runs.
    def rebuild_all_rooms!
      return { rebuilt: 0, rebuild_errors: 0 } unless @reconciler

      rebuilt = 0
      errors = 0
      Room.find_each do |room|
        @reconciler.refresh_one(matrix_room_id: room.matrix_room_id)
        rebuilt += 1
      rescue StandardError
        errors += 1
      end
      { rebuilt: rebuilt, rebuild_errors: errors }
    end

    def require_reconciler!
      raise(NotConfiguredError, "Reconciler not configured — complete /settings first") unless @reconciler
    end
  end
end
