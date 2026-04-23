# frozen_string_literal: true

require "auth/refresh_flow"
require "admin/reconciler"
require "discord/client"

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

    # Operator-initiated pause of the sync loop. The supervisor already
    # gates on AuthState.paused? (lib/bridge/supervisor.rb), so flipping
    # the flag is enough — no thread signalling required. Leaves the
    # Matrix token intact; resume! picks up from the same checkpoint.
    def pause!
      AuthState.pause_by_operator!
      :ok
    end

    def resume!
      AuthState.resume_by_operator!
      :ok
    end

    # Destructive, three-stage rebuild:
    #   1. Delete the actual Discord channels we're tracking so no stale
    #      channels are left on the server (NotFound tolerated).
    #   2. Wipe every Room's cached channel + webhook + last_event_id,
    #      delete the PostedEvent dedup cache, clear the sync checkpoint.
    #   3. If a reconciler is wired, iterate every room and run it through
    #      refresh_one — new channels + webhooks + backfilled recent history.
    # Room metadata (counterparty_matrix_id, counterparty_username) is
    # preserved so the rebuilt channels get their right names immediately.
    def full_resync!
      delete_stats = delete_existing_discord_channels!
      clear_stats = nuke_persisted_state!
      rebuild_stats = rebuild_all_rooms!
      delete_stats.merge(clear_stats).merge(rebuild_stats)
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

    def end_chat!(matrix_room_id:)
      require_reconciler!
      @reconciler.end_chat!(matrix_room_id: matrix_room_id)
    end

    def restore_chat!(matrix_room_id:)
      require_reconciler!
      @reconciler.restore_chat!(matrix_room_id: matrix_room_id)
    end

    # Probes the Discord side end-to-end by posting a visible hello line
    # to #app-status. Useful after changing the bot token or channel
    # IDs on /settings — skips the "wait for the next sync tick to see
    # if it worked" loop. Raises NotConfiguredError when Discord config
    # isn't populated yet, and Discord::Error for any other API failure.
    def test_discord!
      token = AppConfig.fetch("discord_bot_token", "").to_s
      raise(NotConfiguredError, "discord_bot_token is blank — set it on /settings first.") if token.empty?

      channel_id = AppConfig.fetch("discord_admin_status_channel_id", "").to_s
      raise(NotConfiguredError, "discord_admin_status_channel_id is blank — set it on /settings first.") if channel_id.empty?

      client = Discord::Client.new(bot_token: token)
      message_id = client.send_message(
        channel_id: channel_id,
        content: "✅ Connection probe from reddit_chat_bridge · #{Time.current.utc.iso8601}",
      )
      { channel_id: channel_id, message_id: message_id }
    end

    # Accept the Matrix invite so the next /sync carries the room's
    # timeline and the Poster starts bridging. Idempotent: calling a
    # second time short-circuits once the request is resolved.
    def approve_message_request!(id:)
      resolve_message_request!(id: id, decision: MessageRequest::APPROVED) do |request|
        matrix_client.join_room(room_id: request.matrix_room_id)
      end
    end

    # Decline: leave the Matrix room. Reddit surfaces this to the sender
    # as a declined request (matching native Reddit chat semantics).
    def decline_message_request!(id:)
      resolve_message_request!(id: id, decision: MessageRequest::DECLINED) do |request|
        matrix_client.leave_room(room_id: request.matrix_room_id)
      end
    end

    attr_writer :message_request_web_notifier

    private

    def matrix_client
      @matrix_client_factory.call(AuthState.access_token)
    end

    def resolve_message_request!(id:, decision:)
      request = MessageRequest.find(id)
      return request unless request.pending?

      yield(request)
      request.resolve!(decision: decision)
      refresh_discord_message_after_resolve(request)
      request
    end

    # When the operator resolved via the web UI (not a Discord button),
    # the Discord message still shows the original Approve/Decline
    # buttons — visit it via REST and rewrite it to match the resolution.
    # No-op when there's no notifier (tests) or the request never made
    # it into Discord (notifier channel was empty).
    def refresh_discord_message_after_resolve(request)
      return unless @message_request_web_notifier
      return unless request.discord_channel_id && request.discord_message_id

      @message_request_web_notifier.edit_resolution!(request)
    rescue StandardError
      # Failure to update the Discord card is cosmetic — the authoritative
      # state is the DB row, which is already correct.
      nil
    end

    def delete_existing_discord_channels!
      return { channels_deleted: 0, channel_delete_errors: 0 } unless @reconciler

      @reconciler.delete_all_discord_channels!
    end

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
