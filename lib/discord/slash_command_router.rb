# frozen_string_literal: true

module Discord
  # Maps a Discord "interaction" payload (a slash command fired in
  # #commands) to the matching Admin::Actions call and builds the JSON
  # response Discord expects back on the same HTTP connection.
  #
  # All commands are admin-scoped: the handler verifies the interaction's
  # guild + (optionally) channel match what AppConfig has on file so a
  # compromised bot token elsewhere can't drive this bridge.
  class SlashCommandRouter
    # Discord interaction types
    TYPE_PING                = 1
    TYPE_APPLICATION_COMMAND = 2

    # Discord interaction callback types
    CALLBACK_PONG                    = 1
    CALLBACK_CHANNEL_MESSAGE         = 4
    CALLBACK_EPHEMERAL_FLAG          = 64 # private reply only visible to invoker

    def initialize(admin_actions:, guild_id:, commands_channel_id: nil)
      @admin_actions = admin_actions
      @guild_id = guild_id.to_s
      @commands_channel_id = commands_channel_id.to_s
    end

    def dispatch(payload)
      type = payload["type"]
      return pong if type == TYPE_PING
      return not_command unless type == TYPE_APPLICATION_COMMAND
      return wrong_channel unless allowed?(payload)

      name = payload.dig("data", "name")
      handler = COMMANDS[name] || method(:unknown_command)
      response_text = handler.call(self, payload)
      ephemeral(response_text)
    rescue StandardError => e
      ephemeral("⚠️ #{e.class}: #{e.message}")
    end

    # -------- handlers (invoked via COMMANDS table below) --------

    def status_handler(_payload)
      sync = Bridge::Application.running? ? "running" : "stopped"
      matrix = matrix_auth_label
      last = SyncCheckpoint.current.last_batch_at
      cookie = AuthState.reddit_session_expires_at

      [
        "**Status**",
        "• Sync: `#{sync}`",
        "• Matrix auth: `#{matrix}`",
        ("• Last /sync batch: `#{last.utc.iso8601}`" if last),
        ("• Reddit cookie expires: `#{cookie.utc.iso8601}`" if cookie),
      ].compact.join("\n")
    end

    def resync_handler(_payload)
      @admin_actions.resync
      "✅ Cleared the /sync checkpoint. Next iteration will pull recent history."
    end

    def pause_handler(_payload)
      @admin_actions.pause!
      "⏸ Sync paused. Run `/resume` to start again."
    end

    def resume_handler(_payload)
      @admin_actions.resume!
      "▶ Sync resumed. Next iteration runs within 5 seconds."
    end

    def reconcile_handler(_payload)
      stats = @admin_actions.reconcile_channels!
      "✅ Reconciled: #{stats[:renamed]} renamed, #{stats[:skipped]} skipped, #{stats[:errors]} errors."
    end

    def refresh_token_handler(_payload)
      result = @admin_actions.refresh_matrix_token!
      "✅ Minted a fresh Matrix token. Expires #{result.expires_at&.utc&.iso8601 || "unknown"}."
    end

    def ping_handler(_payload)
      "🏓 pong"
    end

    # Non-destructive refresh of every room. Same pass the per-card
    # Refresh button does, applied in one sweep — useful after fixing a
    # Discord permissions problem or just to catch up quietly.
    def rebuild_handler(_payload)
      stats = @admin_actions.rebuild_all!
      "✅ Rebuild: #{stats[:rebuilt]} room(s) refreshed (#{stats[:rebuild_errors]} errors)."
    end

    # Probe Discord end-to-end by posting a visible hello to #app-status.
    # Same as the Send probe button on /actions.
    def test_discord_handler(_payload)
      @admin_actions.test_discord!
      "✅ Probe posted to #app-status. If you see it there, the bot config is working."
    end

    # Invoked from inside a `#dm-*` channel — payload.channel_id is the
    # Discord channel tied to a Room, so we can resolve it without
    # asking the operator to type an argument. Ends the chat (leaves
    # the Matrix room, deletes the Discord channel, wipes local state);
    # a future DM from the same user comes in as a fresh message request.
    def endchat_handler(payload)
      per_channel_room(payload) do |room|
        display = room.counterparty_username || room.matrix_room_id
        @admin_actions.end_chat!(matrix_room_id: room.matrix_room_id)
        "✅ Ended chat with **#{display}**. Future messages arrive as a new message request."
      end
    end

    # Archive the current `#dm-*` channel's room. Deletes the Discord
    # channel, marks the Room archived, but keeps us joined to the
    # Matrix room — so a future Reddit message from this user auto-
    # unarchives and mints a fresh channel.
    def archive_handler(payload)
      per_channel_room(payload) do |room|
        display = room.counterparty_username || room.matrix_room_id
        result = @admin_actions.archive_room!(matrix_room_id: room.matrix_room_id)
        if result == :already_archived
          "ℹ️ **#{display}** was already archived."
        else
          "✅ Archived **#{display}** - Discord channel deleted; a new message will auto-unarchive."
        end
      end
    end

    # Refresh the current `#dm-*` room: re-fetch profile, rename channel
    # if needed, replay recent history. Mirrors the per-card Refresh
    # button on /rooms.
    def refresh_handler(payload)
      per_channel_room(payload) do |room|
        display = room.counterparty_username || room.matrix_room_id
        result = @admin_actions.refresh_room!(matrix_room_id: room.matrix_room_id)
        rename_note = result[:renamed] ? "renamed" : "unchanged"
        "✅ Refreshed **#{display}** - channel #{rename_note}, #{result[:posted_attempted]} event(s) re-examined."
      end
    end

    # Dump the current `#dm-*` room's details ephemerally — useful for
    # debugging when something looks off and you don't want to open the
    # web UI.
    def room_handler(payload)
      per_channel_room(payload) do |room|
        lines = ["**Room ##{room.id} · #{room.counterparty_username || "unresolved"}**"]
        lines << "• Matrix ID: `#{room.matrix_room_id}`"
        lines << "• Counterparty: `#{room.counterparty_matrix_id || "unknown"}`"
        lines << "• Discord channel: `#{room.discord_channel_id || "—"}`"
        lines << "• Webhook: #{room.discord_webhook_id ? "cached" : "not yet created"}"
        lines << "• Last event: `#{room.last_event_id || "—"}`"
        lines << "• State: #{room_state_label(room)}"
        lines.join("\n")
      end
    end

    def room_state_label(room)
      return "terminated (hidden)" if room.terminated?
      return "archived" if room.archived?
      return "pending (no channel yet)" if room.discord_channel_id.nil?

      "linked"
    end

    def unknown_command(_router, payload)
      "❓ Unknown command `#{payload.dig("data", "name")}`"
    end

    # Public specs Discord uses when the operator asks us to register
    # commands. Each entry is `{ name:, description: }`.
    # Discord caps descriptions at 100 characters. Per-room commands
    # also can't use an em-dash in descriptions safely in some locales;
    # sticking to ASCII hyphens here keeps the bulk-register call from
    # tripping "Invalid Form Body".
    COMMAND_DEFINITIONS = [
      { name: "status",        description: "Show the bridge's sync and auth state" },
      { name: "pause",         description: "Pause the /sync loop without dropping the Matrix token" },
      { name: "resume",        description: "Resume the /sync loop after a manual pause" },
      { name: "resync",        description: "Clear the /sync checkpoint and re-pull recent history" },
      { name: "reconcile",     description: "Sweep every room and rename channels to current usernames" },
      { name: "refresh_token", description: "Mint a fresh Matrix JWT from the stored Reddit cookies" },
      { name: "ping",          description: "Health check - replies pong" },
      { name: "rebuild",       description: "Refresh every room - rename + replay recent history (non-destructive)" },
      { name: "test_discord",  description: "Probe Discord by posting a hello line to #app-status" },
      { name: "refresh",       description: "Refresh this chat - rename + replay recent history (inside a #dm-* channel)" },
      { name: "archive",       description: "Archive this chat - channel deleted; auto-recreates on next message (inside #dm-*)" },
      { name: "endchat",       description: "Hide this chat - delete channel and drop future events (inside a #dm-* channel)" },
      { name: "room",          description: "Show diagnostic info for this chat (inside a #dm-* channel)" },
    ].freeze

    COMMANDS = {
      "status" => ->(r, p) { r.status_handler(p) },
      "pause" => ->(r, p) { r.pause_handler(p) },
      "resume" => ->(r, p) { r.resume_handler(p) },
      "resync" => ->(r, p) { r.resync_handler(p) },
      "reconcile" => ->(r, p) { r.reconcile_handler(p) },
      "refresh_token" => ->(r, p) { r.refresh_token_handler(p) },
      "ping" => ->(r, p) { r.ping_handler(p) },
      "rebuild" => ->(r, p) { r.rebuild_handler(p) },
      "test_discord" => ->(r, p) { r.test_discord_handler(p) },
      "refresh" => ->(r, p) { r.refresh_handler(p) },
      "archive" => ->(r, p) { r.archive_handler(p) },
      "endchat" => ->(r, p) { r.endchat_handler(p) },
      "room" => ->(r, p) { r.room_handler(p) },
    }.freeze

    # Commands that are meant to be invoked from a `#dm-*` channel rather
    # than from #commands — they derive their target from the current
    # channel_id, so forcing them into #commands would defeat the point.
    UNRESTRICTED_CHANNEL_COMMANDS = ["endchat", "archive", "refresh", "room"].freeze

    private

    def matrix_auth_label
      return "paused by operator" if AuthState.paused_by_operator?
      return "paused - token rejected" if AuthState.paused?

      "ok"
    end

    # Shared lookup for per-room slash commands: resolves the channel
    # the interaction fired in to a Room and yields. Returns a polite
    # error string when the channel isn't bridged.
    def per_channel_room(payload)
      room = Room.find_by(discord_channel_id: payload["channel_id"].to_s)
      return "🚫 Run this inside a `#dm-*` channel - no bridged room matches this channel." unless room

      yield(room)
    end

    # Only accept commands from the configured guild — and, if an admin
    # channel id is configured, only from that channel. Anywhere else
    # returns a polite nope. A small allow-list of "per-room" commands
    # is exempt from the channel restriction so they can be run in the
    # target `#dm-*` channel itself.
    def allowed?(payload)
      return false unless payload["guild_id"].to_s == @guild_id
      return true if @commands_channel_id.empty?
      return true if UNRESTRICTED_CHANNEL_COMMANDS.include?(payload.dig("data", "name"))

      payload["channel_id"].to_s == @commands_channel_id
    end

    def pong
      { type: CALLBACK_PONG }
    end

    def not_command
      ephemeral("❓ Unsupported interaction type.")
    end

    def wrong_channel
      ephemeral("🚫 This command must be run in the configured #commands channel of the bridge's guild.")
    end

    def ephemeral(text)
      {
        type: CALLBACK_CHANNEL_MESSAGE,
        data: { content: text, flags: CALLBACK_EPHEMERAL_FLAG },
      }
    end
  end
end
