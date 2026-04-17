# frozen_string_literal: true

module Discord
  # Posts operational log lines to `#app-logs`. Info/warn/error levels with
  # a simple `LEVEL` prefix in monospaced code ticks so the channel reads
  # like a tail of a structured log file.
  #
  # Like AdminNotifier, swallows underlying client errors — failing to log
  # should never fail the request being logged about.
  class Logger
    LEVELS = [:info, :warn, :error].freeze

    def initialize(client:, logs_channel_id:)
      @client = client
      @logs_channel_id = logs_channel_id
    end

    LEVELS.each do |level|
      define_method(level) do |message|
        send_safely(level, message)
      end
    end

    private

    def send_safely(level, message)
      content = "`#{level.to_s.upcase}` #{message}"
      @client.send_message(channel_id: @logs_channel_id, content: content)
    rescue Discord::Error, StandardError
      nil
    end
  end
end
