# frozen_string_literal: true

require "discord/client"

module Admin
  # Ensures the four Discord system channels (#app-status, #app-logs,
  # #commands, #message-requests) exist under a given category and are
  # ordered per the operator's preference.
  #
  # For each slug it resolves to one of three outcomes:
  #   - :kept    -> the stored ID points at a live channel already under
  #                 the target category; nothing to do.
  #   - :moved   -> the stored ID is live but under a different category;
  #                 PATCH parent_id to move it. Same ID, same history.
  #   - :created -> no stored ID (or stored ID returned 404); create a
  #                 fresh channel under the target category and write
  #                 the new ID into AppConfig.
  #
  # Idempotent: a second run with the same inputs is a no-op save for
  # the closing `reorder_channels` call (which Discord treats as a no-op
  # when positions already match).
  class SystemChannelProvisioner
    SYSTEM_CHANNELS = [
      {
        slug: "status",
        name: "app-status",
        topic: "Critical alerts · bridge status",
        description: "Critical alerts · bridge status",
        config_key: "discord_admin_status_channel_id",
      },
      {
        slug: "logs",
        name: "app-logs",
        topic: "Operational log stream",
        description: "Operational log stream",
        config_key: "discord_admin_logs_channel_id",
      },
      {
        slug: "commands",
        name: "commands",
        topic: "Slash-command surface · restrict to @BotAdmin",
        description: "Slash-command surface",
        config_key: "discord_admin_commands_channel_id",
      },
      {
        slug: "message_requests",
        name: "message-requests",
        topic: "Incoming Reddit DMs pending Approve/Decline",
        description: "Reddit DM intake · Approve/Decline",
        config_key: "discord_message_requests_channel_id",
      },
    ].freeze
    BY_SLUG = SYSTEM_CHANNELS.to_h { |row| [row[:slug], row] }.freeze
    DEFAULT_ORDER = SYSTEM_CHANNELS.map { |row| row[:slug] }.freeze

    def initialize(client:, guild_id:, journal:)
      @client = client
      @guild_id = guild_id
      @journal = journal
    end

    def provision!(category_id:, order:)
      outcomes = normalize_order(order).map.with_index do |slug, position|
        spec = BY_SLUG.fetch(slug)
        id, outcome = resolve_channel(spec, category_id)
        AppConfig.set(spec[:config_key], id) if outcome == :created
        { slug: slug, id: id, outcome: outcome, position: position }
      end

      @client.reorder_channels(
        guild_id: @guild_id,
        positions: outcomes.map { |o| { id: o[:id], position: o[:position] } },
      )

      journal_summary(outcomes, category_id)
      outcomes
    end

    private

    def normalize_order(csv)
      requested = csv.to_s.split(",").map(&:strip).reject(&:empty?)
      known = requested & DEFAULT_ORDER
      missing = DEFAULT_ORDER - known
      known + missing
    end

    def resolve_channel(spec, category_id)
      stored = AppConfig.get(spec[:config_key]).to_s
      unless stored.empty?
        begin
          channel = @client.get_channel(stored)
          return [stored, :kept] if channel["parent_id"].to_s == category_id.to_s

          @client.update_channel(channel_id: stored, parent_id: category_id)
          return [stored, :moved]
        rescue Discord::NotFound
          # Stored ID is gone — fall through to create.
        end
      end

      id = @client.create_channel(
        guild_id: @guild_id,
        name: spec[:name],
        parent_id: category_id,
        topic: spec[:topic],
      )
      [id, :created]
    end

    def journal_summary(outcomes, category_id)
      counts = outcomes.group_by { |o| o[:outcome] }.transform_values(&:count)
      @journal.info(
        "System channels provisioned: " \
        "created=#{counts[:created] || 0} " \
        "moved=#{counts[:moved] || 0} " \
        "kept=#{counts[:kept] || 0} " \
        "category=#{category_id}",
        source: "system_channel_provisioner",
      )
    end
  end
end
