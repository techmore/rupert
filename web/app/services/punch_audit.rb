# frozen_string_literal: true

# The detailed punch audit trail (Settings → Time rules → Punch logging). When the workspace has it
# on, every clock in, clock out, break, punch fix and refused PIN is written to the activity log
# as `time_clock.<event>` with how it was made (source, store, device, register) and, only when the
# workspace also turned that on, the network address. Off by default: nothing is written.
#
# The punch itself (ClockShift, ClockBreak, ClockCorrection) is the record of hours and is kept
# whatever this says; the trail is the extra "who touched the clock, from where" evidence.
class PunchAudit
  PREFIX = 'time_clock.'

  class << self
    def record(event, shift: nil, worker: nil, **details)
      rules = TimeRules.for(nil)
      return unless rules.punch_audit_trail?

      data = { source: shift&.source, shift_id: shift&.id, location_id: shift&.location_id, device: shift&.device_label,
               register: shift&.register_name, at: Time.current.iso8601 }.merge(details).compact
      ip = Current.metadata[:punch_ip]
      data[:ip] = ip if rules.punch_ip_logging? && ip.present?
      ActivityLogger.log("#{PREFIX}#{event}", subject: worker || shift&.employee, details: data.to_json)
    end

    # Removes audit lines older than the workspace's choice (3, 4 or 7 years). The general activity
    # log keeps seven years (DataRetention); this only ever shortens the punch trail.
    def prune!(now: Time.current)
      cutoff = now - TimeRules.for(nil).punch_audit_retention_years.years
      ActivityLog.where('action LIKE ?', "#{PREFIX}%").where(created_at: ...cutoff).delete_all
    end
  end
end
