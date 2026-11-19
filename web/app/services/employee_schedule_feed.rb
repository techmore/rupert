# frozen_string_literal: true

# A worker's posted shifts as an iCalendar feed for their phone's calendar app. The URL carries a
# signed token for that worker only (no session), so it can be subscribed to; the token is tied to
# the worker id and the workspace and can be rotated by changing the secret salt.
class EmployeeScheduleFeed
  SALT = 'employee-schedule-feed'

  def self.verifier
    Rails.application.message_verifier(SALT)
  end

  def self.token(worker)
    verifier.generate({ employee_id: worker.id, tenant_id: worker.tenant_id })
  end

  def self.valid?(worker, token)
    data = verifier.verified(token)
    data.is_a?(Hash) && data['employee_id'] == worker.id && data['tenant_id'] == worker.tenant_id
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    false
  end

  def self.ics(worker)
    shifts = worker.scheduled_shifts.live.published.where('ends_at > ?', 8.weeks.ago).chronological.includes(:location).to_a
    lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Rupert//Shifts//EN', 'CALSCALE:GREGORIAN', 'X-WR-CALNAME:My shifts']
    shifts.each do |shift|
      summary = ['Shift', shift.label, shift.location&.name].compact.join(' · ')
      lines.concat(['BEGIN:VEVENT', "UID:rupert-shift-#{shift.tenant_id}-#{shift.id}", "DTSTAMP:#{stamp(shift.updated_at)}",
        "DTSTART:#{stamp(shift.starts_at)}", "DTEND:#{stamp(shift.ends_at)}", "SUMMARY:#{escape(summary)}",
        ("DESCRIPTION:#{escape(shift.notes)}" if shift.notes.present?), 'END:VEVENT'].compact)
    end
    lines << 'END:VCALENDAR'
    lines.join("\r\n") + "\r\n"
  end

  def self.stamp(time) = time.utc.strftime('%Y%m%dT%H%M%SZ')
  def self.escape(text) = text.to_s.gsub('\\', '\\\\').gsub(',', '\,').gsub(';', '\;').gsub("\n", '\n')
end
