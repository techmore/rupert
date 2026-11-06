# frozen_string_literal: true

class ClockShift < ApplicationRecord
  include TenantScoped
  include LockedPayPeriodGuard

  # A punch cannot be added to, or moved within, a locked pay period (only the dates that change are checked).
  guards_pay_period { [(new_record? || started_at_changed?) ? started_at : nil, ended_at_changed? ? ended_at : nil] }

  belongs_to :user, optional: true
  belongs_to :employee, class_name: 'People::Employee', optional: true
  has_many :corrections, class_name: 'ClockCorrection', dependent: :restrict_with_exception
  has_many :breaks, class_name: 'ClockBreak', dependent: :destroy
  has_many :tip_allocations, dependent: :nullify
  belongs_to :location, optional: true
  belongs_to :scheduled_shift, class_name: 'People::ScheduledShift', optional: true

  SOURCES = %w[web pos ios api manager import].freeze
  validates :source, inclusion: { in: SOURCES }

  attr_readonly :tenant_id, :user_id, :employee_id, :employee_key, :employee_name, :employment_type, :request_token
  validates :tenant_id, :employee_key, :employee_name, :employment_type, :started_at, :request_token, presence: true
  validates :request_token, format: { with: /\A[a-zA-Z0-9_-]{16,64}\z/ }
  validate :ordered_interval
  validate :non_overlapping_interval
  validate :linked_worker, on: :create

  # No real shift is longer than this; a longer interval is a forgotten clock-out to correct.
  MAX_SHIFT_HOURS = 24
  # Default for the workspace's forgotten clock-out limit (PayRules open_shift_limit_hours): a punch
  # still open after it is flagged and counts no hours, commission or tips until it is corrected.
  STALE_OPEN_HOURS = 16

  scope :open, -> { where(ended_at: nil) }
  scope :stale_open, ->(at = Time.current) { open.where('started_at < ?', at - stale_open_hours.hours) }

  def self.stale_open_hours
    PayRules.current.open_shift_limit_hours
  end
  scope :recent, -> { order(started_at: :desc, id: :desc) }

  # Gross hours between the punches (breaks included), as before.
  def hours(at: Time.current)
    [(ended_at || at) - started_at, 0].max / 3600.0
  end

  # Seconds of unpaid break inside the shift (the location's rules decide which kinds are unpaid).
  def unpaid_break_seconds(at: Time.current, rules: nil)
    rules ||= TimeRules.for(location_id)
    breaks.sum { |b| rules.break_paid?(b.kind) ? 0 : b.seconds(at: [at, ended_at].compact.min) }
  end

  # Hours that count for pay: punches minus unpaid breaks.
  def paid_hours(at: Time.current, rules: nil)
    [(hours(at: at) * 3600) - unpaid_break_seconds(at: at, rules: rules), 0].max / 3600.0
  end

  def open_break = breaks.detect(&:open?)
  def on_break? = open_break.present?
  def open? = ended_at.nil?
  def closed? = ended_at.present?

  def break_minutes(kind = nil)
    (kind ? breaks.select { |b| b.kind == kind.to_s } : breaks).sum(&:minutes)
  end

  # Where an estimate stops counting this shift: the clock-out, or for a punch that is still open
  # `at`, now. A forgotten clock-out (open past the limit) counts nothing until it is corrected.
  def counted_end(at = Time.current)
    return ended_at if ended_at
    return started_at if stale_open?(at)

    at
  end

  def stale_open?(at = Time.current)
    ended_at.nil? && started_at < at - self.class.stale_open_hours.hours
  end

  # All changes for one worker share a writer lock before interval reads.
  # A missing historical worker falls back to the tenant row, retaining the
  # ability to close/review shifts after employee deletion.
  def self.serialize_worker(employee_key)
    raise ActiveRecord::RecordNotFound unless Current.tenant_id.present?

    transaction do
      Tenant.where(id: Current.tenant_id).update_all('updated_at = updated_at')
      locked = People::Employee.where(id: employee_key).update_all('updated_at = updated_at')
      Tenant.where(id: Current.tenant_id).update_all('updated_at = updated_at') if locked.zero?
      yield
    end
  end

  def serialize_change
    raise ActiveRecord::RecordNotFound unless Current.tenant_id.present? && tenant_id == Current.tenant_id

    self.class.serialize_worker(employee_key) do
      self.class.where(id: id).update_all('lock_version = lock_version + 1')
      reload
      yield
    end
  end

  private

  def ordered_interval
    return if started_at.nil?

    errors.add(:started_at, 'cannot be in the future') if started_at > Time.current
    errors.add(:ended_at, 'must be after clock-in') if ended_at && ended_at <= started_at
    errors.add(:ended_at, 'cannot be in the future') if ended_at && ended_at > Time.current
    if ended_at && ended_at > started_at + MAX_SHIFT_HOURS.hours
      errors.add(:ended_at, "must be within #{MAX_SHIFT_HOURS} hours of clock-in")
    end
  end

  def non_overlapping_interval
    return if started_at.nil? || employee_key.blank?

    scope = self.class.where(employee_key: employee_key).where.not(id: id)
    scope = scope.where('ended_at IS NULL OR ended_at > ?', started_at)
    scope = scope.where('started_at < ?', ended_at) if ended_at
    errors.add(:base, 'This interval overlaps another shift for this worker') if scope.exists?
    if employee_id && SquareTimecard.overlapping(employee_id, started_at, ended_at).exists?
      errors.add(:base, 'This interval overlaps imported Square hours; request a correction for review')
    end
  end

  def linked_worker
    return if user&.active? && employee&.active? && employee.user_id == user_id &&
      employee.tenant_id == tenant_id && employee_key == employee.id.to_s

    errors.add(:employee, 'must be an active worker linked to this sign-in account and store')
  end
end
