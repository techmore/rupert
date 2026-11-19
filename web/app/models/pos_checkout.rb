# frozen_string_literal: true

class PosCheckout < ApplicationRecord
  include TenantScoped
  belongs_to :location
  belongs_to :pos_terminal, optional: true
  belongs_to :user
  belongs_to :pos_display_session
  belongs_to :pos_session, class_name: 'Sales::PosSession', optional: true
  belongs_to :order, class_name: 'Core::Order', optional: true
  belongs_to :compliance_override_by, class_name: 'User', optional: true
  has_many :pos_stock_allocations
  has_many :pos_payment_attempts
  has_many :pos_card_reversals
  serialize :lines_json, coder: JSON
  serialize :compliance_issues_json, coder: JSON
  encrypts :lines_json
  validates :reference, uniqueness: true
  validates :status, inclusion: { in: %w[ready processing unknown declined paid cancelled] }
  # card_a920: the card was run on the store's SwipeSimple Pax A920 terminal and
  # the cashier records it here, like cash. No gateway is called. Its payment is
  # method card (card clearing 1150, SwipeSimple tender match) with a reference
  # starting TERMINAL_REFERENCE_PREFIX, so it is told apart from gateway charges.
  TERMINAL_CARD = 'card_a920'
  TERMINAL_REFERENCE_PREFIX = 'swipesimple_a920'
  TENDERS = ['cash', 'card', TERMINAL_CARD].freeze
  TENDER_LABELS = { 'cash' => 'Cash', 'card' => 'Card', TERMINAL_CARD => 'Card (A920)' }.freeze
  validates :tender, inclusion: { in: TENDERS }
  validates :subtotal_cents, :tax_cents, :tip_cents, :total_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate do
    errors.add(:base, 'Checkout belongs to another workspace.') unless [location, user, pos_display_session, pos_session, order].compact.all? { |row| row.tenant_id == tenant_id }
    errors.add(:total_cents, 'must equal subtotal, tax and tip') unless total_cents == subtotal_cents.to_i + tax_cents.to_i + tip_cents.to_i
  end
  def lines = lines_json || []
  def compliance_issues = compliance_issues_json || []
  def compliance_override? = compliance_override_by_id.present?
  validates :gateway_provider, inclusion: { in: PosSetting::CREDENTIAL_KEYS.keys }
  def sandbox_payment? = tender == 'card' && %w[nmi dejavoo_spin].include?(gateway_provider) && environment == 'sandbox'
  def terminal_card? = tender == TERMINAL_CARD
  def payment_method = tender == 'cash' ? 'cash' : 'card'
  def tender_label = TENDER_LABELS.fetch(tender, tender.to_s.humanize)
  def paid? = status == 'paid'
  def unresolved? = %w[processing unknown].include?(status)
  def dejavoo_terminal? = tender == 'card' && gateway_provider == 'dejavoo_spin' && !demo?

  def receipt
    { id: id, reference: reference, status: status, demo: demo?, sandbox: sandbox_payment?, tender: tender, tender_label: tender_label, subtotal_cents: subtotal_cents,
      tax_cents: tax_cents, tip_cents: tip_cents, total_cents: total_cents, cash_received_cents: cash_received_cents,
      change_cents: change_cents, paid_at: paid_at&.iso8601,
      inventory_pending: pos_stock_allocations.where.not(status: %w[applied released]).exists?,
      terminal: dejavoo_terminal?, card: card_receipt, decline_reason: status == 'declined' ? latest_attempt&.decline_reason : nil }
  end

  def gateway_label = { 'nmi' => 'NMI', 'authorize_net' => 'Authorize.net', 'dejavoo_spin' => 'Dejavoo terminal' }.fetch(gateway_provider, gateway_provider.to_s)

  def paid_attempt = pos_payment_attempts.find_by(status: 'paid')

  def latest_attempt = pos_payment_attempts.order(:id).last

  # Card details for the receipt, from the verified gateway record. Never a card number.
  def card_receipt
    return nil unless tender == 'card' && paid?

    attempt = paid_attempt
    return nil unless attempt

    { processor: gateway_label, brand: attempt.card_brand, last_four: attempt.card_last_four, auth_code: attempt.auth_code,
      transaction_id: attempt.transaction_id, refunded_cents: pos_card_reversals.succeeded.sum(:amount_cents) }
  end
end
