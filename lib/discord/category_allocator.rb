# frozen_string_literal: true

module Discord
  class CategoryAllocator
    SPILLOVER_KEY = "discord_dms_spillover_category_ids"
    ENABLED_KEY = "discord_dms_spillover_enabled"
    DEFAULT_BASE_NAME = "Reddit DMs"
    SOURCE = "category_allocator"

    def initialize(client:, guild_id:, primary_category_id:, journal: nil)
      @client = client
      @guild_id = guild_id
      @primary_category_id = primary_category_id
      @journal = journal
    end

    def create_channel(name:, topic:)
      @client.create_channel(guild_id: @guild_id, name: name, parent_id: current_category_id, topic: topic)
    rescue Discord::BadRequest => exception
      raise unless category_full?(exception)

      unless spillover_enabled?
        @journal&.warn(
          "Reddit DMs category full and spillover disabled - DM not bridged; enable spillover in /settings.",
          source: SOURCE,
        )
        raise
      end

      spillover_id = open_spillover_category!
      @client.create_channel(guild_id: @guild_id, name: name, parent_id: spillover_id, topic: topic)
    end

    private

    def current_category_id
      spillover_ids.last || @primary_category_id
    end

    def category_full?(error)
      error.message.include?("CHANNEL_PARENT_MAX_CHANNELS")
    end

    def spillover_enabled?
      AppConfig.fetch(ENABLED_KEY, "true") != "false"
    end

    # Copies the primary category's name + permission overwrites so a spillover
    # category is private by default (channels inherit their parent's perms).
    def open_spillover_category!
      name = next_spillover_name
      id = @client.create_category(guild_id: @guild_id, name: name, permission_overwrites: primary_overwrites)
      AppConfig.set(SPILLOVER_KEY, (spillover_ids + [id]).join(","))
      @journal&.info("Reddit DMs category full; created spillover category '#{name}' (#{id}).", source: SOURCE)
      id
    rescue Discord::AuthError
      # Setting overwrites on create needs Manage Roles; without it we'd only be
      # able to make a public category, which would leak the operator's DMs.
      @journal&.critical(
        "Spillover category needs the Manage Roles permission to stay private. Re-invite the bot with Manage Roles.",
        source: SOURCE,
      )
      raise
    rescue Discord::BadRequest
      @journal&.critical(
        "Discord guild channel cap reached - cannot create more DM channels. Archive old DMs to free space.",
        source: SOURCE,
      )
      raise
    end

    def next_spillover_name
      "#{base_category_name} #{spillover_ids.size + 2}"
    end

    def base_category_name
      primary_category&.dig("name").to_s.strip.presence || DEFAULT_BASE_NAME
    end

    def primary_overwrites
      primary_category&.dig("permission_overwrites")
    end

    def primary_category
      return @primary_category if defined?(@primary_category)

      @primary_category = @client.get_channel(@primary_category_id)
    rescue Discord::Error
      @primary_category = nil
    end

    def spillover_ids
      AppConfig.fetch(SPILLOVER_KEY, "").to_s.split(",").map(&:strip).reject(&:empty?)
    end
  end
end
