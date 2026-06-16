# frozen_string_literal: true

module Bridge
  class HistoryCutoff
    LOOKBACK_KEY = "bridge_history_lookback_days"
    DATE_KEY = "bridge_history_cutoff_date"

    def cutoff_time(now: Time.current)
      [lookback_cutoff(now), date_cutoff].compact.max
    end

    private

    def lookback_cutoff(now)
      days = Integer(AppConfig.fetch(LOOKBACK_KEY, "").to_s.strip, exception: false)
      return if days.nil? || days <= 0

      now - days.days
    end

    def date_cutoff
      raw = AppConfig.fetch(DATE_KEY, "").to_s.strip
      return if raw.empty?

      date = parse_date(raw)
      return unless date

      Time.utc(date.year, date.month, date.day)
    end

    def parse_date(raw)
      Date.iso8601(raw)
    rescue Date::Error
      nil
    end
  end
end
