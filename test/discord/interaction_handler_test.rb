# frozen_string_literal: true

require "test_helper"
require "discord/client"
require "discord/interaction_handler"

module Discord
  class InteractionHandlerTest < ActiveSupport::TestCase
    APP_ID = "app_1"
    INTERACTION_ID = "int_1"
    TOKEN = "tok_int"

    setup do
      @client = mock("Discord::Client")
      @slash = mock("SlashCommandRouter")
      @component = mock("MessageComponentRouter")
      @scheduled = []
      # Inline scheduler: capture blocks so tests run them explicitly and
      # can assert on ACK-before-work ordering.
      @scheduler = ->(&block) { @scheduled << block }

      @handler = Discord::InteractionHandler.new(
        client: @client,
        slash_command_router: @slash,
        message_component_router: @component,
        scheduler: @scheduler,
      )
    end

    # ---- button clicks ----

    test "button click ACKs with DEFERRED_UPDATE_MESSAGE (type 6) before running the router" do
      payload = button_payload(custom_id: "mr:approve:5")
      @component.expects(:dispatch).never # router must not run synchronously

      @client.expects(:create_interaction_response).with(
        interaction_id: INTERACTION_ID,
        interaction_token: TOKEN,
        payload: { type: 6 },
      ).returns(:ok)

      @handler.call(payload)

      assert_equal(1, @scheduled.size, "deferred work should be scheduled exactly once")
    end

    test "after the deferred ACK, the router runs and @original is edited with its data payload" do
      payload = button_payload(custom_id: "mr:approve:5")
      @client.stubs(:create_interaction_response).returns(:ok)
      @component.expects(:dispatch).with(payload).returns(
        { type: 7, data: { embeds: [{ title: "Approved" }], components: [] } },
      )
      @client.expects(:edit_original_interaction_response).with(
        application_id: APP_ID,
        interaction_token: TOKEN,
        payload: { embeds: [{ title: "Approved" }], components: [] },
      ).returns(:ok)

      @handler.call(payload)
      run_scheduled_work
    end

    test "when the router raises, the handler surfaces the failure via journal but doesn't crash the scheduler thread" do
      payload = button_payload(custom_id: "mr:approve:5")
      journal = mock("Journal")
      journal.stubs(:info)
      journal.expects(:warn).with(regexp_matches(/interaction callback failed.*boom/i), source: "gateway")

      handler = Discord::InteractionHandler.new(
        client: @client,
        slash_command_router: @slash,
        message_component_router: @component,
        journal: journal,
        scheduler: @scheduler,
      )

      @client.stubs(:create_interaction_response).returns(:ok)
      @component.expects(:dispatch).raises(StandardError, "boom")
      @client.expects(:edit_original_interaction_response).never

      handler.call(payload)
      run_scheduled_work
    end

    # ---- slash commands ----

    test "slash command ACKs with DEFERRED_CHANNEL_MESSAGE (type 5) + ephemeral flag so the 'thinking…' pill stays private" do
      payload = command_payload(name: "status")

      @client.expects(:create_interaction_response).with(
        interaction_id: INTERACTION_ID,
        interaction_token: TOKEN,
        payload: { type: 5, data: { flags: 64 } },
      ).returns(:ok)
      @slash.expects(:dispatch).never

      @handler.call(payload)
    end

    test "slash command follow-up edits @original with the router's data payload" do
      payload = command_payload(name: "status")
      @client.stubs(:create_interaction_response).returns(:ok)
      @slash.expects(:dispatch).with(payload).returns(
        { type: 4, data: { content: "ok", flags: 64 } },
      )
      @client.expects(:edit_original_interaction_response).with(
        application_id: APP_ID,
        interaction_token: TOKEN,
        payload: { content: "ok", flags: 64 },
      ).returns(:ok)

      @handler.call(payload)
      run_scheduled_work
    end

    # Regression: /endchat and /archive delete the channel the ephemeral
    # "thinking…" message lives in, so the edit_original PATCH 404s. The
    # command succeeded, so don't alert #app-status.
    test "a 404 on edit_original is journaled at info (not warn) — self-destructive commands kill their own response" do
      payload = command_payload(name: "endchat")
      journal = mock("Journal")
      journal.stubs(:info)
      journal.expects(:warn).never

      handler = Discord::InteractionHandler.new(
        client: @client,
        slash_command_router: @slash,
        message_component_router: @component,
        journal: journal,
        scheduler: @scheduler,
      )

      @client.stubs(:create_interaction_response).returns(:ok)
      @slash.expects(:dispatch).with(payload).returns({ type: 4, data: { content: "ok" } })
      @client.expects(:edit_original_interaction_response).raises(Discord::NotFound, "Unknown Message")

      handler.call(payload)
      run_scheduled_work
    end

    # ---- ACK failure ----

    test "an ACK failure is journaled but does not raise" do
      payload = button_payload(custom_id: "mr:approve:5")
      journal = mock("Journal")
      journal.stubs(:info)
      journal.expects(:warn).with(regexp_matches(/interaction ACK failed/), source: "gateway")

      handler = Discord::InteractionHandler.new(
        client: @client,
        slash_command_router: @slash,
        message_component_router: @component,
        journal: journal,
        scheduler: @scheduler,
      )

      @client.expects(:create_interaction_response).raises(Discord::ServerError, "503")

      assert_nothing_raised { handler.call(payload) }
      assert_empty(@scheduled, "scheduler must not run when ACK failed")
    end

    test "unknown interaction type is ignored — nothing is sent to Discord" do
      payload = { "id" => INTERACTION_ID, "application_id" => APP_ID, "token" => TOKEN, "type" => 99 }
      @client.expects(:create_interaction_response).never

      @handler.call(payload)

      assert_empty(@scheduled)
    end

    private

    def button_payload(custom_id:)
      {
        "id" => INTERACTION_ID,
        "application_id" => APP_ID,
        "token" => TOKEN,
        "type" => 3,
        "data" => { "custom_id" => custom_id, "component_type" => 2 },
      }
    end

    def command_payload(name:)
      {
        "id" => INTERACTION_ID,
        "application_id" => APP_ID,
        "token" => TOKEN,
        "type" => 2,
        "data" => { "name" => name },
      }
    end

    def run_scheduled_work
      @scheduled.shift.call until @scheduled.empty?
    end
  end
end
