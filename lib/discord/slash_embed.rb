# frozen_string_literal: true

require "discord/colors"

module Discord
  # Builder for Discord embed payloads used by slash command responses.
  # Slash commands respond ephemerally (only the invoker sees them); each
  # response is one embed in the bridge's color palette plus an optional
  # action row for confirm/select flows.
  #
  # Use the level-based constructors (`success`, `info`, `warn`, `error`,
  # `diagnostic`) so the color palette stays consistent across commands.
  # `kv_fields` covers the common "name → value" shape with sensible
  # formatting for nil / Time / boolean values.
  module SlashEmbed
    extend self

    EPHEMERAL_FLAG = 64

    def success(title:, description: nil, fields: [], footer: nil)
      build(color: Colors::MOSS, title: title, description: description, fields: fields, footer: footer)
    end

    def info(title:, description: nil, fields: [], footer: nil)
      build(color: Colors::EMBER, title: title, description: description, fields: fields, footer: footer)
    end

    def warn(title:, description: nil, fields: [], footer: nil)
      build(color: Colors::AMBER, title: title, description: description, fields: fields, footer: footer)
    end

    def error(message:, title: "Error")
      build(color: Colors::RUST, title: title, description: message, fields: [], footer: nil)
    end

    def diagnostic(title:, description: nil, fields: [], footer: nil)
      build(color: Colors::SLATE, title: title, description: description, fields: fields, footer: footer)
    end

    def kv_fields(pairs, inline: true)
      pairs.map { |name, value| { name: name.to_s, value: format_value(value), inline: inline } }
    end

    def ephemeral(embed, components: nil)
      payload = { embeds: [embed], flags: EPHEMERAL_FLAG }
      payload[:components] = components if components
      payload
    end

    class << self
      private

      def build(color:, title:, description:, fields:, footer:)
        embed = { color: color, title: title }
        embed[:description] = description if description
        embed[:fields] = fields if fields && !fields.empty?
        embed[:footer] = { text: footer } if footer
        embed
      end

      def format_value(value)
        case value
        when nil then "—"
        when Time, DateTime then value.utc.iso8601
        when true then "yes"
        when false then "no"
        else value.to_s
        end
      end
    end
  end
end
