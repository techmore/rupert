# frozen_string_literal: true

module SquareTimesheetsHelper
  def square_latest_values(card)
    record = JSON.parse(card.latest_payload.presence || card.source_payload.presence || '{}')
    record = {} unless record.is_a?(Hash)
    zone = Time.find_zone(record['timezone']) if record['timezone'].is_a?(String)
    pauses = record['breaks'].is_a?(Array) ? record['breaks'] : []
    { started_at: square_source_time(record['start_at']), ended_at: square_source_time(record['end_at']),
      timezone: zone&.tzinfo&.name, status: %w[OPEN CLOSED].include?(record['status']) ? record['status'] : nil,
      breaks: pauses.filter_map do |pause|
        next unless pause.is_a?(Hash)

        { name: pause['name'].is_a?(String) ? pause['name'] : nil,
          started_at: square_source_time(pause['start_at']), ended_at: square_source_time(pause['end_at']),
          is_paid: [true, false].include?(pause['is_paid']) ? pause['is_paid'] : nil }
      end }
  rescue JSON::ParserError, TypeError, ArgumentError
    { started_at: nil, ended_at: nil, timezone: nil, status: nil, breaks: [] }
  end

  def square_source_time(value)
    Time.iso8601(value) if value.is_a?(String) && value.match?(/(?:Z|[+-]\d\d:\d\d)\z/)
  rescue ArgumentError
    nil
  end

  def square_punch_label(time, timezone)
    return 'Not available' unless time

    l(timezone ? time.in_time_zone(timezone) : time, format: '%b %-d, %Y · %-I:%M:%S %p %Z')
  end

  def square_hours(seconds)
    number_with_precision(BigDecimal(seconds.to_i.to_s) / 3600, precision: 2)
  end

  # Signed hours with a real minus sign: "+0.50", "−1.25", "0.00".
  def square_hours_delta(seconds)
    return '0.00' if seconds.to_i.zero?

    "#{seconds.negative? ? '−' : '+'}#{square_hours(seconds.abs)}"
  end

  # "Mon Oct 5 · 9:00 AM – 5:00 PM" in the card's own timezone.
  def square_shift_label(started_at, ended_at, timezone)
    return 'Not available' unless started_at

    zone = (timezone.is_a?(String) && Time.find_zone(timezone)) || Time.zone
    from = started_at.in_time_zone(zone)
    to = ended_at&.in_time_zone(zone)
    finish =
      if to.nil? then 'open'
      elsif to.to_date == from.to_date then l(to, format: '%-I:%M %p')
      else l(to, format: '%a %b %-d %-I:%M %p')
      end
    "#{l(from, format: '%a %b %-d')} · #{l(from, format: '%-I:%M %p')} – #{finish}"
  end

  def square_history_title(event)
    case event[:kind]
    when 'seen' then ['Square version', event[:source_version], 'read'].compact.join(' ')
    when 'missing' then 'Missing from Square'
    when 'accepted' then 'Square’s version accepted'
    when 'kept' then 'Original hours kept'
    when 'held' then 'Accept held: period locked'
    end
  end
end
