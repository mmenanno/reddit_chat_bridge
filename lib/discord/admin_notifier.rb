# frozen_string_literal: true

module Discord
  # Posts operator-facing alerts to the `#app-status` channel.
  #
  # Separate from the per-conversation poster on purpose: admin messages
  # live in a dedicated channel, carry severity indicators, and can `@everyone`
  # on truly fatal events. Errors from the underlying client are caught and
  # swallowed — a broken admin channel should never take the bridge down,
  # because the bridge is what would otherwise alert us that the admin
  # channel is broken.
  class AdminNotifier
    INDICATORS = { info: "🟢", warn: "🟡", critical: "🔴" }.freeze

    def initialize(client:, status_channel_id:)
      @client = client
      @status_channel_id = status_channel_id
    end

    def info(message)
      post(:info, message)
    end

    def warn(message)
      post(:warn, message)
    end

    def critical(message, ping_everyone: true)
      prefix = INDICATORS.fetch(:critical)
      prefix = "#{prefix} @everyone" if ping_everyone
      send_safely("#{prefix} #{message}")
    end

    private

    def post(level, message)
      send_safely("#{INDICATORS.fetch(level)} #{message}")
    end

    def send_safely(content)
      @client.send_message(channel_id: @status_channel_id, content: content)
    rescue Discord::Error, StandardError
      # Intentionally swallowed — the alert channel being broken must not
      # cascade into a process crash. The underlying stderr log still has
      # the failure for post-mortem.
      nil
    end
  end
end
