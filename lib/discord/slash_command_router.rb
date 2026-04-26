# frozen_string_literal: true

require "bridge/build_info"
require "discord/colors"
require "discord/slash_embed"
require "matrix/sync_loop"

module Discord
  # Maps a Discord "interaction" payload (a slash command fired in
  # #commands) to the matching Admin::Actions call and builds the
  # ephemeral embed Discord shows back to the operator.
  #
  # Handlers return a full interaction-response `data` Hash (built via
  # `Discord::SlashEmbed.ephemeral`), so each handler chooses its own
  # embed shape and optional action-row components. The router only
  # wraps it in the outer `{type: ..., data: ...}` envelope and handles
  # the cross-cutting auth checks (guild/channel allow-list).
  class SlashCommandRouter
    # Discord interaction types
    TYPE_PING                = 1
    TYPE_APPLICATION_COMMAND = 2

    # Discord interaction callback types
    CALLBACK_PONG                    = 1
    CALLBACK_CHANNEL_MESSAGE         = 4

    BUTTON_STYLE_PRIMARY   = 1
    BUTTON_STYLE_SECONDARY = 2
    BUTTON_STYLE_SUCCESS   = 3
    BUTTON_STYLE_DANGER    = 4
    COMPONENT_TYPE_ACTION_ROW = 1
    COMPONENT_TYPE_BUTTON     = 2

    # Discord caps action rows at 5 buttons; cap our match list to leave
    # room for a Cancel button.
    UNARCHIVE_MAX_MATCHES = 4
    RESTORE_MAX_MATCHES   = 4

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
      data = handler.call(self, payload)
      { type: CALLBACK_CHANNEL_MESSAGE, data: data }
    rescue StandardError => e
      error_response("#{e.class}: #{e.message}")
    end

    # -------- handlers (invoked via COMMANDS table below) --------

    def status_handler(_payload)
      sync_label = Bridge::Application.running? ? "✅ running" : "⏹ stopped"
      matrix     = matrix_auth_label
      last       = SyncCheckpoint.current.last_batch_at
      cookie     = AuthState.reddit_session_expires_at

      description = []
      description << cookie_warning(cookie) if cookie_warning(cookie)
      description << "**Sync:** #{sync_label}"
      description << "**Matrix auth:** #{matrix}"
      description << "**Cadence:** long-poll · #{Matrix::SyncLoop::DEFAULT_TIMEOUT_MS / 1000}s idle timeout (real-time when events arrive)"

      fields = []
      fields << { name: "Last /sync batch", value: relative_with_iso(last), inline: false } if last
      fields << { name: "Reddit cookie", value: reddit_cookie_label(cookie), inline: false } if cookie

      embed = SlashEmbed.info(
        title: "Bridge status",
        description: description.join("\n"),
        fields: fields,
        footer: "v#{Bridge::BuildInfo.version}",
      )
      SlashEmbed.ephemeral(embed)
    end

    # Forces the next /sync iteration to be an initial sync (no `since`
    # token) by clearing the SyncCheckpoint. Rare but unique value: it
    # re-fetches pending invites in one shot and re-establishes a fresh
    # sync baseline if the checkpoint is stale. /rebuild is the heavier
    # per-room hammer for "I'm missing events"; /resync is the lighter
    # "I think the sync state itself is off" lever.
    def resync_handler(_payload)
      @admin_actions.resync
      timeout_s = Matrix::SyncLoop::DEFAULT_TIMEOUT_MS / 1000
      SlashEmbed.ephemeral(SlashEmbed.success(
        title: "Sync checkpoint cleared",
        description: "Next `/sync` iteration runs within ~#{timeout_s}s and pulls a fresh baseline (initial sync). " \
                     "PostedEvent dedup keeps replay safe.",
      ))
    end

    def pause_handler(_payload)
      @admin_actions.pause!
      embed = SlashEmbed.warn(
        title: "⏸ Sync paused",
        description: "Run `/resume` to start it again.",
      )
      SlashEmbed.ephemeral(embed)
    end

    def resume_handler(_payload)
      @admin_actions.resume!
      embed = SlashEmbed.success(
        title: "▶ Sync resumed",
        description: "Next iteration runs within 5 seconds.",
      )
      SlashEmbed.ephemeral(embed)
    end

    def reconcile_handler(_payload)
      stats = @admin_actions.reconcile_channels!
      fields = SlashEmbed.kv_fields([
        ["Renamed",   stats[:renamed]],
        ["Unchanged", stats[:unchanged]],
        ["Skipped",   stats[:skipped]],
        ["Errors",    stats[:errors]],
      ])
      SlashEmbed.ephemeral(SlashEmbed.success(title: "Reconcile complete", fields: fields))
    end

    def refresh_token_handler(_payload)
      result = @admin_actions.refresh_matrix_token!
      fields = SlashEmbed.kv_fields([["Expires", result.expires_at]])
      SlashEmbed.ephemeral(SlashEmbed.success(title: "Matrix token refreshed", fields: fields))
    end

    def ping_handler(_payload)
      SlashEmbed.ephemeral(SlashEmbed.info(
        title: "🏓 pong",
        description: "Bridge v#{Bridge::BuildInfo.version} is responsive.",
      ))
    end

    # Non-destructive refresh of every active room. Mirrors the per-card
    # Refresh button on /rooms — useful after fixing a Discord permissions
    # problem or just to catch up quietly.
    def rebuild_handler(_payload)
      stats = @admin_actions.rebuild_all!
      fields = SlashEmbed.kv_fields([
        ["Refreshed",                 stats[:rebuilt]],
        ["Skipped (archived/hidden)", stats[:rebuild_skipped]],
        ["Errors",                    stats[:rebuild_errors]],
      ])
      SlashEmbed.ephemeral(SlashEmbed.success(title: "Rebuild complete", fields: fields))
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
        embed = SlashEmbed.warn(
          title: "Ended chat with #{display}",
          description: "Future messages from this user arrive as a new message request.",
        )
        SlashEmbed.ephemeral(embed)
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
        embed = if result == :already_archived
          SlashEmbed.info(
            title: "Already archived",
            description: "#{display} was already archived.",
          )
        else
          SlashEmbed.warn(
            title: "Archived #{display}",
            description: "Discord channel deleted; a new message will auto-unarchive.",
          )
        end
        SlashEmbed.ephemeral(embed)
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
        fields = SlashEmbed.kv_fields([
          ["Channel", rename_note],
          ["Events re-examined", result[:posted_attempted]],
        ])
        SlashEmbed.ephemeral(SlashEmbed.success(title: "Refreshed #{display}", fields: fields))
      end
    end

    # Dump the current `#dm-*` room's details ephemerally — useful for
    # debugging when something looks off and you don't want to open the
    # web UI.
    def room_handler(payload)
      per_channel_room(payload) do |room|
        fields = SlashEmbed.kv_fields(
          [
            ["Matrix ID", room.matrix_room_id],
            ["Counterparty",    room.counterparty_matrix_id],
            ["Discord channel", room.discord_channel_id],
            ["Webhook",         room.discord_webhook_id ? "cached" : "not yet created"],
            ["Last event",      room.last_event_id],
            ["State",           room_state_label(room)],
          ],
          inline: false,
        )

        embed = SlashEmbed.diagnostic(
          title: "Room ##{room.id} · #{room.counterparty_username || "unresolved"}",
          fields: fields,
        )
        embed[:thumbnail] = { url: room.counterparty_avatar_url } if room.counterparty_avatar_url.present?
        SlashEmbed.ephemeral(embed)
      end
    end

    # Fuzzy-match an archived room by its Reddit username, then surface
    # a confirm/select flow via action-row buttons (handled by the
    # MessageComponentRouter on click).
    def unarchive_handler(payload)
      query = command_option(payload, "query").to_s.strip
      return error_response_data("Provide a username to unarchive.") if query.empty?

      matches = match_archived_rooms(query)
      surface_match_picker(matches: matches, query: query, prefix: "unarchive", title_verb: "Unarchive")
    end

    # Counterpart of /unarchive for terminated (hidden) chats.
    def restore_handler(payload)
      query = command_option(payload, "query").to_s.strip
      return error_response_data("Provide a username to restore.") if query.empty?

      matches = match_terminated_rooms(query)
      surface_match_picker(matches: matches, query: query, prefix: "restore", title_verb: "Restore")
    end

    def room_state_label(room)
      return "terminated (hidden)" if room.terminated?
      return "archived" if room.archived?
      return "pending (no channel yet)" if room.discord_channel_id.nil?

      "linked"
    end

    def unknown_command(_router, payload)
      error_response_data("Unknown command `#{payload.dig("data", "name")}`")
    end

    # Public specs Discord uses when the operator asks us to register
    # commands. Each entry is `{ name:, description:, options? }`.
    # Discord caps descriptions at 100 characters. Per-room commands
    # also can't use an em-dash in descriptions safely in some locales;
    # sticking to ASCII hyphens here keeps the bulk-register call from
    # tripping "Invalid Form Body".
    COMMAND_DEFINITIONS = [
      { name: "status",        description: "Show the bridge's sync and auth state" },
      { name: "pause",         description: "Pause the /sync loop without dropping the Matrix token" },
      { name: "resume",        description: "Resume the /sync loop after a manual pause" },
      { name: "resync",        description: "Clear the /sync checkpoint and force a fresh initial sync" },
      { name: "reconcile",     description: "Sweep every room and rename channels to current usernames" },
      { name: "refresh_token", description: "Mint a fresh Matrix JWT from the stored Reddit cookies" },
      { name: "ping",          description: "Health check - replies pong" },
      { name: "rebuild",       description: "Refresh every active room - rename + replay recent history" },
      { name: "refresh",       description: "Refresh this chat - rename + replay recent history (inside a #dm-* channel)" },
      { name: "archive",       description: "Archive this chat - channel deleted; auto-recreates on next message (inside #dm-*)" },
      { name: "endchat",       description: "Hide this chat - delete channel and drop future events (inside a #dm-* channel)" },
      { name: "room",          description: "Show diagnostic info for this chat (inside a #dm-* channel)" },
      {
        name: "unarchive",
        description: "Unarchive a chat by Reddit username (fuzzy match)",
        options: [{
          type: 3, # STRING
          name: "query",
          description: "Reddit username (or part of it) to search archived rooms for",
          required: true,
        }],
      },
      {
        name: "restore",
        description: "Restore a previously hidden (ended) chat by Reddit username (fuzzy match)",
        options: [{
          type: 3,
          name: "query",
          description: "Reddit username (or part of it) to search hidden rooms for",
          required: true,
        }],
      },
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
      "refresh" => ->(r, p) { r.refresh_handler(p) },
      "archive" => ->(r, p) { r.archive_handler(p) },
      "endchat" => ->(r, p) { r.endchat_handler(p) },
      "room" => ->(r, p) { r.room_handler(p) },
      "unarchive" => ->(r, p) { r.unarchive_handler(p) },
      "restore" => ->(r, p) { r.restore_handler(p) },
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

    # Returns "<relative> · <iso>" for a Time, or "—" when nil. The
    # relative half is what the operator scans first; the iso is there
    # for copy-paste into log queries.
    def relative_with_iso(time)
      return unless time

      "#{relative_time(time)} · #{time.utc.iso8601}"
    end

    def relative_time(time)
      seconds = (Time.current - time).to_i
      return "in the future" if seconds.negative?
      return "just now" if seconds < 30
      return "#{seconds}s ago" if seconds < 60
      return "#{seconds / 60}m ago" if seconds < 3600
      return "#{seconds / 3600}h ago" if seconds < 86_400

      "#{seconds / 86_400}d ago"
    end

    def reddit_cookie_label(time)
      return unless time

      seconds_left = (time - Time.current).to_i
      return "expired (#{time.utc.iso8601})" if seconds_left.negative?

      days = seconds_left / 86_400
      "#{days}d left · expires #{time.utc.iso8601}"
    end

    def cookie_warning(time)
      return unless time

      seconds_left = (time - Time.current).to_i
      return "🔴 Reddit session expired - paste a fresh cookie jar in /auth." if seconds_left.negative?
      return "🔴 Reddit session expires in <24h - refresh the cookie jar in /auth." if seconds_left < 86_400
      return "🟡 Reddit session expires in <7 days - plan a refresh." if seconds_left < 7 * 86_400

      nil
    end

    # Shared lookup for per-room slash commands: resolves the channel
    # the interaction fired in to a Room and yields. Returns a polite
    # error embed when the channel isn't bridged.
    def per_channel_room(payload)
      room = Room.find_by(discord_channel_id: payload["channel_id"].to_s)
      return error_response_data("Run this inside a #dm-* channel - no bridged room matches this channel.") unless room

      yield(room)
    end

    def command_option(payload, name)
      options = payload.dig("data", "options") || []
      options.find { |o| o["name"] == name }&.dig("value")
    end

    def match_archived_rooms(query)
      fuzzy_match(Room.where.not(archived_at: nil).where(terminated_at: nil), query)
    end

    def match_terminated_rooms(query)
      fuzzy_match(Room.where.not(terminated_at: nil), query)
    end

    # Substring match with priority: exact > prefix > contains. Cheap
    # and dependency-free; the username space is small (~dozens to
    # hundreds of rooms in practice) so the in-process scan is fine.
    def fuzzy_match(scope, query)
      needle = query.downcase
      candidates = scope.where.not(counterparty_username: nil).to_a
      ranked = candidates.filter_map do |room|
        name = room.counterparty_username.to_s.downcase
        rank = if name == needle then 0
        elsif name.start_with?(needle) then 1
        elsif name.include?(needle) then 2
        end
        [rank, room] if rank
      end
      ranked.sort_by { |rank, _| rank }.map(&:last)
    end

    def surface_match_picker(matches:, query:, prefix:, title_verb:)
      return no_matches_response(query: query, title_verb: title_verb) if matches.empty?

      if matches.size == 1
        room = matches.first
        return confirm_response(room: room, prefix: prefix, title_verb: title_verb)
      end

      multi_match_response(matches: matches, query: query, prefix: prefix, title_verb: title_verb)
    end

    def no_matches_response(query:, title_verb:)
      SlashEmbed.ephemeral(SlashEmbed.error(
        title: "#{title_verb} - no match",
        message: "No rooms matched `#{query}`. Try a shorter substring of the Reddit username.",
      ))
    end

    def confirm_response(room:, prefix:, title_verb:)
      display = room.counterparty_username
      embed = SlashEmbed.info(
        title: "Confirm: #{title_verb.downcase} #{display}?",
        description: "Matrix room `#{room.matrix_room_id}` (room ##{room.id}).",
      )
      row = action_row([
        button(custom_id: "#{prefix}:confirm:#{room.id}", style: BUTTON_STYLE_SUCCESS, label: "Yes, #{title_verb.downcase}", emoji: "✅"),
        button(custom_id: "#{prefix}:cancel:#{room.id}",  style: BUTTON_STYLE_SECONDARY, label: "Cancel"),
      ])
      SlashEmbed.ephemeral(embed, components: [row])
    end

    def multi_match_response(matches:, query:, prefix:, title_verb:)
      pickable = matches.first(UNARCHIVE_MAX_MATCHES)
      lines = pickable.each_with_index.map { |r, i| "#{i + 1}. **#{r.counterparty_username}** · room ##{r.id}" }
      footer = matches.size > pickable.size ? "Showing #{pickable.size} of #{matches.size} matches; refine the query for more." : nil
      embed = SlashEmbed.info(
        title: "#{title_verb} - #{matches.size} matches for `#{query}`",
        description: lines.join("\n"),
        footer: footer,
      )
      buttons = pickable.each_with_index.map do |room, i|
        button(
          custom_id: "#{prefix}:select:#{room.id}",
          style: BUTTON_STYLE_PRIMARY,
          label: "#{i + 1}. #{room.counterparty_username}",
        )
      end
      buttons << button(custom_id: "#{prefix}:cancel:0", style: BUTTON_STYLE_SECONDARY, label: "Cancel")
      SlashEmbed.ephemeral(embed, components: [action_row(buttons)])
    end

    def action_row(buttons)
      { type: COMPONENT_TYPE_ACTION_ROW, components: buttons }
    end

    def button(custom_id:, style:, label:, emoji: nil)
      btn = { type: COMPONENT_TYPE_BUTTON, style: style, custom_id: custom_id, label: label }
      btn[:emoji] = { name: emoji } if emoji
      btn
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
      error_response("Unsupported interaction type.")
    end

    def wrong_channel
      error_response("This command must be run in the configured #commands channel of the bridge's guild.")
    end

    def error_response(message)
      { type: CALLBACK_CHANNEL_MESSAGE, data: error_response_data(message) }
    end

    def error_response_data(message)
      SlashEmbed.ephemeral(SlashEmbed.error(message: message))
    end
  end
end
