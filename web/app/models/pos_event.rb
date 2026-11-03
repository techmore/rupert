# frozen_string_literal: true

# A show, market or pop-up (F70 event mode). The owner picks approved catalog
# items and preset prices while it is a draft; opening it (after the pre-event
# checklist) freezes that list. Only the listed staff sell, only from that list,
# through the event register. Closing it records the cash count, the card
# terminal batch total and counted stock for end-of-event reconciliation.
class PosEvent < ApplicationRecord
  include TenantScoped

  STATUSES = %w[draft open closed].freeze
  CHECKLIST = {
    'items_reviewed' => 'Event items and prices reviewed',
    'coas_ready' => 'A current COA is ready for every item (printed or by QR code)',
    'staff_briefed' => 'Staff briefed: check ID (21+), no custom items, no renaming, no health claims',
    'terminal_ready' => 'Card terminal charged and signed in, or card sales are off for this event',
    'float_counted' => 'Opening cash float counted'
  }.freeze
  MAX_ITEMS = 60

  belongs_to :location
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :opened_by, class_name: 'User', optional: true
  belongs_to :closed_by, class_name: 'User', optional: true
  has_many :pos_event_items, -> { order(:position, :id) }, dependent: :destroy, inverse_of: :pos_event
  has_many :pos_event_sales, dependent: :restrict_with_error

  serialize :staff_user_ids_json, coder: JSON
  serialize :checklist_json, coder: JSON
  normalizes :name, :venue, with: ->(value) { value.to_s.squish.presence }

  validates :name, presence: true, length: { maximum: 80 }
  validates :venue, length: { maximum: 120 }
  validates :status, inclusion: { in: STATUSES }
  validates :starts_on, :ends_on, presence: true
  validates :tax_rate_bps, numericality: { only_integer: true, in: 0..2_500 }
  validates :opening_float_cents, numericality: { only_integer: true, in: 0..10_000_000 }
  validates :counted_cash_cents, :terminal_card_total_cents, numericality: { only_integer: true, in: 0..100_000_000 }, allow_nil: true
  validate do
    errors.add(:ends_on, 'must be on or after the start date') if starts_on && ends_on && ends_on < starts_on
    errors.add(:base, 'Event belongs to another workspace.') if location && location.tenant_id != tenant_id
  end

  scope :recent, -> { order(starts_on: :desc, id: :desc) }

  def draft? = status == 'draft'
  def open? = status == 'open'
  def closed? = status == 'closed'
  def staff_user_ids = Array(staff_user_ids_json).map(&:to_i)
  def staff_users = User.where(tenant_id: tenant_id, id: staff_user_ids).ordered
  def checklist = checklist_json.is_a?(Hash) ? checklist_json : {}
  def checklist_complete? = CHECKLIST.keys.all? { |key| checklist[key] == true }
  def sellable_items = pos_event_items.reject(&:pulled?)

  def staff?(user) = user && staff_user_ids.include?(user.id)

  # Who may ring up sales on the event register.
  def seller?(user) = open? && user&.active? && user.can_use_pos? && (staff?(user) || user.can_approve_pos_override?)

  def tax_cents_for(line_cents) = (BigDecimal(line_cents.to_s) * tax_rate_bps / 10_000).round(0, BigDecimal::ROUND_HALF_UP).to_i

  def sales_summary
    sales = pos_event_sales.to_a
    cash = sales.select { |sale| sale.tender == 'cash' }
    card = sales.select { |sale| sale.tender == 'card_terminal' }
    {
      count: sales.size, subtotal_cents: sales.sum(&:subtotal_cents), tax_cents: sales.sum(&:tax_cents),
      total_cents: sales.sum(&:total_cents), cash_cents: cash.sum(&:total_cents), card_cents: card.sum(&:total_cents),
      cash_count: cash.size, card_count: card.size, overrides: sales.count(&:override?), flagged: sales.count(&:flagged?)
    }
  end

  def expected_cash_cents = opening_float_cents + sales_summary[:cash_cents]
  def cash_variance_cents = counted_cash_cents && counted_cash_cents - expected_cash_cents
  def card_variance_cents = terminal_card_total_cents && terminal_card_total_cents - sales_summary[:card_cents]

  # Units sold per event item id, from the sale lines (never recomputed from prices).
  def units_sold
    pos_event_sales.flat_map(&:lines).each_with_object(Hash.new(0)) { |line, units| units[line['event_item_id'].to_i] += line['quantity'].to_i }
  end
end
