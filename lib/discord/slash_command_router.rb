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
      matrix = AuthState.paused? ? "paused" : "ok"
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

    def unknown_command(_router, payload)
      "❓ Unknown command `#{payload.dig("data", "name")}`"
    end

    # Public specs Discord uses when the operator asks us to register
    # commands. Each entry is `{ name:, description: }`.
    COMMAND_DEFINITIONS = [
      { name: "status",        description: "Show the bridge's sync and auth state" },
      { name: "resync",        description: "Clear the /sync checkpoint and re-pull recent history" },
      { name: "reconcile",     description: "Sweep every room and rename channels to current usernames" },
      { name: "refresh_token", description: "Mint a fresh Matrix JWT from the stored Reddit cookies" },
      { name: "ping",          description: "Health check — replies pong" },
    ].freeze

    COMMANDS = {
      "status" => ->(r, p) { r.status_handler(p) },
      "resync" => ->(r, p) { r.resync_handler(p) },
      "reconcile" => ->(r, p) { r.reconcile_handler(p) },
      "refresh_token" => ->(r, p) { r.refresh_token_handler(p) },
      "ping" => ->(r, p) { r.ping_handler(p) },
    }.freeze

    private

    # Only accept commands from the configured guild — and, if an admin
    # channel id is configured, only from that channel. Anywhere else
    # returns a polite nope.
    def allowed?(payload)
      return false unless payload["guild_id"].to_s == @guild_id

      return true if @commands_channel_id.empty?

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
