# frozen_string_literal: true

# A manager's decision on a Square timecard that was edited or removed in Square
# after import: who decided, when and why, with the counted and latest hours side
# by side. Like ClockCorrection, the record keeps both versions; unlike it, the row
# is written once at decision time and never changes.
class SquareTimecardReview < ApplicationRecord
  # accepted: Square's latest hours now count. kept: the counted hours stay.
  # held: accept was asked for, but a submitted, approved or paid period blocked it.
  DECISIONS = %w[accepted kept held].freeze
  include TenantScoped

  belongs_to :square_timecard
  belongs_to :reviewer, class_name: 'User', foreign_key: :reviewed_by_id, optional: true
  attr_readonly(*%i[tenant_id square_timecard_id reviewed_by_id decision reason status_before counted_digest latest_digest employee_id_before
    employee_id_after counted_started_at counted_ended_at counted_payable_seconds latest_started_at latest_ended_at latest_payable_seconds held_by])
  validates :reason, presence: true, length: { maximum: 1000 }
  validates :decision, inclusion: { in: DECISIONS }
  validates :status_before, presence: true
  validate :same_workspace

  def counted_hours
    BigDecimal(counted_payable_seconds.to_s) / 3600
  end

  def latest_hours
    latest_payable_seconds && BigDecimal(latest_payable_seconds.to_s) / 3600
  end

  # Append-only: once written, a row can be neither saved again nor destroyed.
  def readonly?
    persisted? || super
  end

  private

  def same_workspace
    errors.add(:square_timecard, 'must belong to this workspace') unless square_timecard&.tenant_id == tenant_id
  end
end
