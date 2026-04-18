# frozen_string_literal: true

module Bridge
  # Thin facade that fans out operational events to (a) the EventLogEntry
  # table so the /events page has something to render, (b) the Discord
  # AdminNotifier for #app-status when the level warrants paging, and
  # (c) the Discord Logger for #app-logs when it's just a heartbeat.
  #
  # Every call path that used to poke admin_notifier.warn / .critical
  # directly now goes through here, which means the Discord side and the
  # DB side stay in sync without two different callers to keep aligned.
  class Journal
    INFO     = :info
    WARN     = :warn
    ERROR    = :error
    CRITICAL = :critical

    def initialize(admin_notifier: nil, logger: nil)
      @admin_notifier = admin_notifier
      @logger = logger
    end

    def info(message, source: nil, context: nil)
      record(INFO, message, source: source, context: context)
      @logger&.info(message)
    end

    def warn(message, source: nil, context: nil)
      record(WARN, message, source: source, context: context)
      @admin_notifier&.warn(message)
    end

    def error(message, source: nil, context: nil)
      record(ERROR, message, source: source, context: context)
      @admin_notifier&.warn(message)
    end

    def critical(message, source: nil, context: nil, ping_everyone: false)
      record(CRITICAL, message, source: source, context: context)
      @admin_notifier&.critical(message, ping_everyone: ping_everyone)
    end

    private

    def record(level, message, source:, context:)
      return unless defined?(EventLogEntry) && EventLogEntry.table_exists?

      EventLogEntry.record!(level: level, message: message, source: source, context: context)
    end
  end
end
