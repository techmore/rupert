# frozen_string_literal: true

# One line of the tips ledger: an amount of tip money attributed to one worker (or to nobody, when no
# eligible worker was on shift) from one source. Amounts are signed cents. A reversal (refund, void,
# re-attribution) is a new negative row pointing at the row it undoes; rows are never edited after
# the pay period that holds them is locked.
#
#   source_kind: 'dejavoo_feed_event' | 'authorize_net_transaction' | 'order' | 'declared' | 'manual'
#   tip_method:  'direct' (the cashier who took the card) | 'pool' (shared among the clocked-in staff)
#                | 'cash' (declared by the worker) | 'adjustment' (manager correction)
#   status:      'estimated' (terminal said so, not yet settled) | 'settled' (in a settled batch)
#                | 'reversed' (undone by a later row) | 'carried' (settled after lock; counted in a later period)
class TipAllocation < ApplicationRecord
  include TenantScoped

  SOURCE_KINDS = %w[dejavoo_feed_event authorize_net_transaction order declared manual].freeze
  METHODS = %w[direct pool cash adjustment].freeze
  STATUSES = %w[estimated settled reversed carried].freeze

  belongs_to :employee, class_name: 'People::Employee', optional: true
  belongs_to :clock_shift, optional: true
  belongs_to :reverses, class_name: 'TipAllocation', optional: true
  belongs_to :created_by, class_name: 'User', optional: true

  validates :source_kind, inclusion: { in: SOURCE_KINDS }
  validates :tip_method, inclusion: { in: METHODS }
  validates :status, inclusion: { in: STATUSES }
  validates :amount_cents, :occurred_at, :business_date, presence: true
  validates :amount_cents, numericality: { only_integer: true }
  validate :period_still_open, on: :create

  scope :for_period, ->(starts_on, ends_on) { where(business_date: starts_on..ends_on) }
  scope :counted, -> { where.not(status: 'reversed') }
  scope :unassigned, -> { where(employee_id: nil) }
  scope :card, -> { where(tip_method: %w[direct pool]) }
  scope :cash, -> { where(tip_method: 'cash') }

  before_validation :default_pay_period

  def unassigned? = employee_id.nil?
  def card? = %w[direct pool].include?(tip_method)
  def final? = status == 'settled' || status == 'carried'

  # The hours-wide business date in the location's zone, so an 11:30 PM tip stays on that day.
  def self.business_date_for(time, location_id: nil)
    BusinessClock.date_of(time, tenant: Current.tenant, location: location_id && Location.find_by(id: location_id))
  end

  # Undo this allocation with a mirrored negative row (never deletes). Returns the reversal.
  def reverse!(reason:, source_kind: self.source_kind, source_id: self.source_id, occurred_at: Time.current, created_by: Current.user)
    existing = TipAllocation.find_by(reverses_id: id)
    return existing if existing

    transaction do
      reversal = TipAllocation.create!(employee_id: employee_id, clock_shift_id: clock_shift_id, location_id: location_id,
        source_kind: source_kind, source_id: source_id, source_ref: source_ref, tip_method: tip_method, status: 'settled',
        amount_cents: -amount_cents, gross_tip_cents: gross_tip_cents, share_count: share_count,
        occurred_at: occurred_at, business_date: self.class.business_date_for(occurred_at, location_id: location_id),
        settlement_ref: settlement_ref, reverses: self, evidence: evidence, note: reason, created_by: created_by)
      update_columns(status: 'reversed', updated_at: Time.current)
      reversal
    end
  end

  private

  def default_pay_period
    return if business_date.nil?

    self.pay_period_start ||= PayRules.current.period_start(business_date)
  end

  def period_still_open
    return if business_date.nil?
    return if PayPeriod.open_for?(business_date)

    # Late money (a batch settling after the lock) is carried into the next open period instead of refused.
    period = PayPeriod.next_open_from(business_date)
    if period
      self.pay_period_start = period.starts_on
      self.status = 'carried' unless status == 'reversed'
    else
      errors.add(:business_date, 'falls in a locked pay period')
    end
  end
end
