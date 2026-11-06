# frozen_string_literal: true

class TimeClockService
  class Error < StandardError; end

  # A PIN punch's outcome: the worker, their shift after the punch, what happened (`event`) and the
  # state to show (`clocked_in`, `clocked_out`, `on_break`). `stale` is a forgotten clock-out that
  # still needs fixing before a new shift can start.
  Result = Struct.new(:worker, :shift, :event, :state, :stale, :at, keyword_init: true)

  PUNCH_ACTIONS = %w[punch clock_in clock_out break meal end_break fix_and_clock_in].freeze

  def self.worker_for(user, include_on_leave: false)
    statuses = include_on_leave ? %w[active on_leave] : ['active']
    workers = People::Employee.where(tenant_id: Current.tenant_id, user_id: user.id, status: statuses).limit(2).to_a
    workers.one? ? workers.first : nil
  end

  # The active worker whose clock PIN matches `pin`, or nil. PINs are unique across a workspace
  # (set_clock_pin! refuses a PIN another worker already has), so the first match is the person.
  def self.worker_by_pin(pin)
    digits = pin.to_s.strip
    return nil unless digits.match?(/\A\d{4,6}\z/)

    People::Employee.where(tenant_id: Current.tenant_id, status: 'active').where.not(pin_digest: nil).order(:id).find do |worker|
      !worker.pin_locked? && BCrypt::Password.new(worker.pin_digest) == digits
    end
  end

  # Sets a worker's PIN, refusing one that another active worker already uses (a shared PIN would
  # clock the wrong person). Raises ArgumentError with a message to show.
  def self.set_clock_pin!(worker, pin, confirmation: nil)
    raise ArgumentError, 'The two PINs did not match. Try again.' if !confirmation.nil? && confirmation.to_s.strip != pin.to_s.strip

    other = worker_by_pin(pin)
    raise ArgumentError, 'That PIN is taken. Choose different digits.' if other && other.id != worker.id

    worker.set_pin!(pin)
  end

  # Clock in. Source and store are recorded on the shift; the same request_token or an already open
  # shift returns that shift (safe to retry). `at` is only honoured for queued offline punches from a
  # trusted device, and never in the future or more than a day back.
  def self.clock_in(user:, request_token:, source: 'web', location_id: nil, device_label: nil, register_name: nil, at: nil, worker: nil)
    worker ||= worker_for(user)
    raise Error, 'Ask an administrator to link exactly one active worker record to your sign-in account.' unless worker

    ClockShift.serialize_worker(worker.id) do
      worker.reload
      unless worker.active? && worker.tenant_id == Current.tenant_id && (user.nil? || worker.user_id == user.id)
        raise Error, 'Your worker link changed. Ask an administrator to check your active worker record.'
      end
      existing = ClockShift.find_by(employee_id: worker.id, request_token: request_token)
      existing ||= ClockShift.open.find_by(employee_id: worker.id)
      existing || ClockShift.create!(user_id: worker.user_id, employee: worker, employee_key: worker.id.to_s,
        employee_name: worker.name, employment_type: worker.employment_type,
        started_at: punch_time(at, location_id), request_token: request_token, source: source,
        location_id: location_id.presence, device_label: device_label.presence, register_name: register_name.presence,
        scheduled_shift_id: planned_shift_id(worker, punch_time(at, location_id)))
    end
  rescue ActiveRecord::RecordNotUnique
    ClockShift.find_by(employee_id: worker.id, request_token: request_token) || ClockShift.open.find_by!(employee_id: worker.id)
  end

  # Clock out. Ends an open break first. A punch left open past the longest real shift was a
  # forgotten clock-out: the worker fixes it with a correction instead (see fix_and_clock_in).
  def self.clock_out(user:, shift_id:, at: nil, worker: nil)
    shift = worker ? ClockShift.find_by!(id: shift_id, employee_id: worker.id) : ClockShift.find_by!(id: shift_id, user_id: user.id)
    shift.serialize_change do
      next if shift.ended_at

      if shift.started_at < ClockShift::MAX_SHIFT_HOURS.hours.ago
        raise Error, "This shift has been open more than #{ClockShift::MAX_SHIFT_HOURS} hours. Request a correction with your real clock-out time."
      end

      ended_at = punch_time(at, shift.location_id)
      ended_at = Time.current if ended_at <= shift.started_at
      shift.breaks.open.each { |b| b.update!(ended_at: [ended_at, b.started_at + 1.second].max) }
      shift.update!(ended_at: ended_at)
    end
    shift
  end

  # Starts a rest or meal break on an open shift. One open break at a time (ending the current one first).
  def self.start_break(shift:, kind:)
    raise Error, 'Choose a break or a meal.' unless ClockBreak::KINDS.include?(kind.to_s)

    shift.serialize_change do
      raise Error, 'This shift is already clocked out.' if shift.ended_at
      raise Error, 'This shift was never clocked out. Fix it first.' if shift.stale_open?

      rules = TimeRules.for(shift.location_id)
      shift.breaks.open.each { |b| b.update!(ended_at: Time.current) }
      shift.breaks.create!(kind: kind.to_s, paid: rules.break_paid?(kind), started_at: Time.current)
    end
  end

  def self.end_break(shift:)
    ended = nil
    shift.serialize_change do
      open = shift.breaks.open.first
      raise Error, 'You are not on a break.' unless open

      open.update!(ended_at: [Time.current, open.started_at + 1.second].max)
      ended = open
    end
    ended
  end

  # A punch typed at the register or the counter tablet. `device` is the trusted ClockDevice (or nil);
  # `user` the signed-in account (or nil). One of them must vouch for the worker the PIN names.
  #
  # action 'punch' is the one-tap path: clocks in when the worker is out; when they are already in,
  # it changes nothing and returns the state so the pad can offer Clock out / Break / Meal.
  def self.pin_punch(pin:, action: 'punch', device: nil, user: nil, location_id: nil, register_name: nil, request_token: nil, at: nil, break_kind: nil, proposed_ended_at: nil, reason: nil)
    action = action.to_s.presence || 'punch'
    raise Error, 'Unknown clock action.' unless PUNCH_ACTIONS.include?(action)

    worker = worker_by_pin(pin)
    raise Error, 'That PIN didn’t match.' unless worker
    vouch_for!(worker, device: device, user: user)

    location_id ||= device&.location_id
    at = nil unless device # queued times are only trusted from a registered store device
    shift = ClockShift.open.find_by(employee_id: worker.id)
    stale = shift&.stale_open? ? shift : nil
    now = Time.current

    case action
    when 'punch', 'clock_in'
      if stale
        return Result.new(worker: worker, shift: stale, event: 'needs_fix', state: 'clocked_in', stale: stale, at: now)
      elsif shift
        return Result.new(worker: worker, shift: shift, event: 'already_in', state: state_of(shift), stale: nil, at: now)
      end

      shift = clock_in(user: nil, worker: worker, request_token: request_token.presence || SecureRandom.uuid, source: 'pos',
        location_id: location_id, device_label: device&.name, register_name: register_name, at: at)
      Result.new(worker: worker, shift: shift, event: 'clocked_in', state: 'clocked_in', stale: nil, at: shift.started_at)
    when 'clock_out'
      raise Error, 'You are not clocked in.' unless shift
      raise Error, 'This shift was never clocked out. Fix it first.' if stale

      shift = clock_out(user: nil, worker: worker, shift_id: shift.id, at: at)
      Result.new(worker: worker, shift: shift, event: 'clocked_out', state: 'clocked_out', stale: nil, at: shift.ended_at)
    when 'break', 'meal'
      raise Error, 'Clock in first.' unless shift

      start_break(shift: shift, kind: action == 'meal' ? 'meal' : (break_kind.presence || 'rest'))
      Result.new(worker: worker, shift: shift.reload, event: "#{action}_started", state: 'on_break', stale: nil, at: now)
    when 'end_break'
      raise Error, 'Clock in first.' unless shift

      end_break(shift: shift)
      Result.new(worker: worker, shift: shift.reload, event: 'break_ended', state: 'clocked_in', stale: nil, at: now)
    when 'fix_and_clock_in'
      raise Error, 'Nothing to fix: you clocked out.' unless stale

      ended = parse_time(proposed_ended_at)
      raise Error, 'Pick when you really left.' unless ended && ended > stale.started_at && ended <= now

      fix_forgotten_clock_out!(stale, ended_at: ended, user: user, worker: worker, reason: reason)
      shift = clock_in(user: nil, worker: worker, request_token: request_token.presence || SecureRandom.uuid, source: 'pos',
        location_id: location_id, device_label: device&.name, register_name: register_name)
      Result.new(worker: worker, shift: shift, event: 'fixed_and_clocked_in', state: 'clocked_in', stale: nil, at: shift.started_at)
    end
  end

  # A forgotten clock-out, fixed from the clock itself: the open punch is closed at the time the worker
  # gives (so the day can go on) and a correction is filed for review with the original (no clock-out)
  # kept. `auto_closed_at` marks the shift so reviewers know the time came from the worker, not a punch.
  def self.fix_forgotten_clock_out!(shift, ended_at:, user: nil, worker: nil, reason: nil)
    raise Error, 'Pick when you really left.' unless ended_at && ended_at > shift.started_at && ended_at <= Time.current

    correction = request_correction(user: user, shift_id: shift.id, worker: worker || shift.employee,
      attributes: { proposed_started_at: shift.started_at, proposed_ended_at: ended_at, reason: reason.presence || 'Forgot to clock out.' })
    shift.serialize_change do
      shift.breaks.open.each { |b| b.update!(ended_at: [ended_at, b.started_at + 1.second].max) }
      shift.update!(ended_at: ended_at, auto_closed_at: Time.current)
    end
    correction
  end

  def self.state_of(shift)
    return 'clocked_out' if shift.nil? || shift.ended_at
    return 'on_break' if shift.on_break?

    'clocked_in'
  end

  # The worker for their own shift, or a manager for someone else's (Fix clock-out). Either way it is a
  # pending ClockCorrection: the shift changes only when another reviewer approves it. Break edits ride
  # along as JSON lists of {kind, started_at, ended_at} (original and proposed).
  def self.request_correction(user:, shift_id:, attributes:, worker: nil)
    shift = worker ? ClockShift.find_by!(id: shift_id, employee_id: worker.id) : correctable_shift(user, shift_id)
    correction = nil
    shift.serialize_change do
      proposed_breaks = normalize_breaks(attributes[:proposed_breaks])
      correction = shift.corrections.create!(attributes.slice(:proposed_started_at, :proposed_ended_at, :reason).merge(
        requested_by_id: user&.id, original_started_at: shift.started_at, original_ended_at: shift.ended_at,
        original_breaks_json: shift.breaks.chronological.map { |b| { kind: b.kind, started_at: b.started_at.iso8601, ended_at: b.ended_at&.iso8601 } }.to_json,
        proposed_breaks_json: proposed_breaks&.to_json
      ))
    end
    correction
  end

  def self.correctable_shift(user, shift_id)
    shift = ClockShift.find(shift_id)
    return shift if shift.user_id == user.id
    raise ActiveRecord::RecordNotFound unless OpenClockOuts.manager?(user) && (user.super_admin? || user.tenant_id == Current.tenant_id)

    shift
  end

  def self.review(correction:, reviewer:, approve:, note: nil)
    raise Error, 'Only timesheet reviewers can review clock corrections.' unless ClockCorrection.reviewer?(reviewer)
    raise ActiveRecord::RecordNotFound unless correction.tenant_id == Current.tenant_id &&
      (reviewer.super_admin? || reviewer.tenant_id == Current.tenant_id)

    shift = correction.clock_shift
    # Same rule as timesheets: nobody reviews a change to their own hours.
    if shift.user_id == reviewer.id || correction.requested_by_id == reviewer.id || (shift.employee && shift.employee.user_id == reviewer.id)
      raise Error, 'Another reviewer must review a correction to your own shift.'
    end
    shift.serialize_change do
      correction.reload
      if correction.status != 'pending'
        return correction if correction.status == (approve ? 'approved' : 'rejected')

        raise Error, 'This correction has already been reviewed with a different decision.'
      end

      if approve
        # A shift the worker closed from the clock (fix_forgotten_clock_out!) already carries the proposed time.
        auto_closed = shift.auto_closed_at.present? && correction.original_ended_at.nil? && shift.ended_at == correction.proposed_ended_at
        unless auto_closed || (shift.started_at == correction.original_started_at && shift.ended_at == correction.original_ended_at)
          raise Error, 'This shift changed after the request. Reject it and request a fresh correction.'
        end
        shift.update!(started_at: correction.proposed_started_at, ended_at: correction.proposed_ended_at)
        apply_breaks(shift, correction.proposed_breaks) if correction.proposed_breaks_json.present?
      end
      correction.update!(status: approve ? 'approved' : 'rejected', reviewed_by_id: reviewer.id, reviewed_at: Time.current, review_note: note.presence)
    end
    requester = correction.requester || shift.user
    if requester
      TimeNotifier.approval_decided(requester, what: "Fix to your #{correction.original_started_at.in_time_zone.strftime('%a %b %-d')} punch", approved: approve,
        url: Rails.application.routes.url_helpers.time_clock_path, note: note, key: "correction:#{correction.id}")
    end
    correction
  end

  # ---- helpers ---------------------------------------------------------------------------------

  def self.vouch_for!(worker, device:, user:)
    return if device&.active?
    return if user && worker.user_id == user.id

    if user
      raise Error, 'That PIN belongs to someone else. Use the store register for a colleague’s punch.'
    else
      raise Error, 'Use the store register, or sign in on your phone.'
    end
  end

  # The time to record: a queued offline punch's time when it is plausible, else now; rounded only
  # when the store's rules say so.
  def self.punch_time(at, location_id)
    time = parse_time(at)
    time = nil if time && (time > Time.current || time < 24.hours.ago)
    TimeRules.for(location_id).round_punch(time || Time.current)
  end

  def self.parse_time(value)
    return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
    return nil if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  # The planned shift this punch most likely belongs to (same person, starting within two hours).
  def self.planned_shift_id(worker, at)
    People::ScheduledShift.live.where(employee_id: worker.id).where('starts_at BETWEEN ? AND ?', at - 2.hours, at + 2.hours).order(:starts_at).pick(:id)
  end

  def self.normalize_breaks(list)
    return nil if list.nil?

    Array(list).filter_map do |row|
      row = row.to_h.with_indifferent_access
      next if row[:started_at].blank? || row[:ended_at].blank? || row[:_destroy].to_s == '1'

      { kind: ClockBreak::KINDS.include?(row[:kind].to_s) ? row[:kind].to_s : 'rest',
        started_at: parse_time(row[:started_at])&.iso8601, ended_at: parse_time(row[:ended_at])&.iso8601 }
    end
  end

  def self.apply_breaks(shift, rows)
    rules = TimeRules.for(shift.location_id)
    shift.breaks.destroy_all
    rows.each do |row|
      started = parse_time(row['started_at'])
      ended = parse_time(row['ended_at'])
      next unless started && ended

      shift.breaks.create!(kind: row['kind'], paid: rules.break_paid?(row['kind']), started_at: started, ended_at: ended)
    end
  end
  private_class_method :vouch_for!, :punch_time, :parse_time, :planned_shift_id, :normalize_breaks, :apply_breaks
end
