# frozen_string_literal: true

# A void or refund of a gateway card payment from a Rupert POS checkout (F69).
# Stored before the gateway call; an uncertain outcome stays `unknown` until a
# read-only recheck settles it. Never retried blindly.
class PosCardReversal < ApplicationRecord
  include TenantScoped

  belongs_to :pos_checkout
  belongs_to :pos_payment_attempt
  belongs_to :requested_by, class_name: 'User'
  belongs_to :core_refund, class_name: 'Core::Refund', optional: true

  KINDS = %w[void refund].freeze
  STATUSES = %w[submitting unknown succeeded failed].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :reference, presence: true, uniqueness: true
  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :reason, length: { minimum: 3, maximum: 500 }
  validate do
    records = [pos_checkout, pos_payment_attempt, requested_by].compact
    errors.add(:base, 'Reversal belongs to another workspace.') unless records.all? { |row| row.tenant_id == tenant_id }
    errors.add(:base, 'Payment attempt belongs to another checkout.') if pos_payment_attempt && pos_payment_attempt.pos_checkout_id != pos_checkout_id
  end

  scope :unresolved, -> { where(status: %w[submitting unknown]) }
  scope :succeeded, -> { where(status: 'succeeded') }

  def unresolved? = %w[submitting unknown].include?(status)
end
