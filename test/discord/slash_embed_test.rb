# frozen_string_literal: true

require "test_helper"
require "discord/slash_embed"

module Discord
  class SlashEmbedTest < ActiveSupport::TestCase
    test "success returns a moss-green embed with the title and optional description" do
      embed = SlashEmbed.success(title: "Done", description: "all good")

      assert_equal(Colors::MOSS, embed[:color])
      assert_equal("Done", embed[:title])
      assert_equal("all good", embed[:description])
    end

    test "info uses the ember accent color" do
      assert_equal(Colors::EMBER, SlashEmbed.info(title: "Status")[:color])
    end

    test "warn uses the amber color" do
      assert_equal(Colors::AMBER, SlashEmbed.warn(title: "Paused")[:color])
    end

    test "error uses the rust color and renders the message as the description" do
      embed = SlashEmbed.error(message: "something exploded")

      assert_equal(Colors::RUST, embed[:color])
      assert_equal("something exploded", embed[:description])
    end

    test "error accepts a custom title" do
      embed = SlashEmbed.error(title: "Bridge offline", message: "no token")

      assert_equal("Bridge offline", embed[:title])
      assert_equal("no token", embed[:description])
    end

    test "diagnostic uses slate" do
      assert_equal(Colors::SLATE, SlashEmbed.diagnostic(title: "Room")[:color])
    end

    test "fields are passed through verbatim" do
      embed = SlashEmbed.info(title: "x", fields: [{ name: "A", value: "1", inline: true }])

      assert_equal([{ name: "A", value: "1", inline: true }], embed[:fields])
    end

    test "no fields key when none provided" do
      refute(SlashEmbed.info(title: "x").key?(:fields))
    end

    test "footer is included when provided" do
      embed = SlashEmbed.info(title: "x", footer: "footer text")

      assert_equal({ text: "footer text" }, embed[:footer])
    end

    test "kv_fields formats time values as iso8601" do
      time = Time.utc(2026, 4, 25, 12, 0)
      fields = SlashEmbed.kv_fields([["When", time]])

      assert_equal("2026-04-25T12:00:00Z", fields.first[:value])
    end

    test "kv_fields formats nil as a dash" do
      fields = SlashEmbed.kv_fields([["Webhook", nil]])

      assert_equal("—", fields.first[:value])
    end

    test "kv_fields preserves declared inline flag" do
      inline_fields = SlashEmbed.kv_fields([["A", "1"]], inline: true)
      block_fields  = SlashEmbed.kv_fields([["A", "1"]], inline: false)

      assert(inline_fields.first[:inline])
      refute(block_fields.first[:inline])
    end

    test "ephemeral wraps an embed in the ephemeral payload shape" do
      embed = SlashEmbed.success(title: "Done")
      payload = SlashEmbed.ephemeral(embed)

      assert_equal([embed], payload[:embeds])
      assert_equal(64, payload[:flags])
    end

    test "ephemeral_with_components attaches an action row alongside the embed" do
      embed = SlashEmbed.info(title: "Choose")
      row = { type: 1, components: [] }
      payload = SlashEmbed.ephemeral(embed, components: [row])

      assert_equal([row], payload[:components])
    end
  end
end
