# frozen_string_literal: true

module People
  # Shared by the manager and the self-service availability editors: "HH:MM" inputs to minutes from midnight.
  module AvailabilityParams
    def self.normalize(raw)
      all_day = raw[:all_day].to_s == '1' || raw[:start_time].blank?
      start_minute = all_day ? 0 : minutes(raw[:start_time])
      end_minute = all_day ? 1440 : minutes(raw[:end_time])
      { weekday: raw[:weekday].to_i, kind: raw[:kind].presence || 'unavailable', note: raw[:note].to_s.strip.presence, start_minute: start_minute, end_minute: end_minute }
    end

    def self.minutes(value)
      hours, minutes = value.to_s.split(':').map(&:to_i)
      (hours.to_i * 60) + minutes.to_i
    end
  end
end
