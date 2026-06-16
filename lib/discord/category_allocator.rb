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

    def open_spillover_category!
      name = next_spillover_name
      id = @client.create_category(guild_id: @guild_id, name: name)
      AppConfig.set(SPILLOVER_KEY, (spillover_ids + [id]).join(","))
      @journal&.info("Reddit DMs category full; created spillover category '#{name}' (#{id}).", source: SOURCE)
      id
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
      return @base_category_name if defined?(@base_category_name)

      @base_category_name = fetch_primary_name || DEFAULT_BASE_NAME
    end

    def fetch_primary_name
      @client.get_channel(@primary_category_id)["name"].to_s.strip.presence
    rescue Discord::Error
      nil
    end

    def spillover_ids
      AppConfig.fetch(SPILLOVER_KEY, "").to_s.split(",").map(&:strip).reject(&:empty?)
    end
  end
end
