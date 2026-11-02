# frozen_string_literal: true

# One sale on an event register. `client_sale_id` is generated on the device
# before sending, so a retried or offline-queued sale is recorded once
# (unique per event). Lines hold the frozen event prices; the canonical order
# (source rupert_pos) carries the same totals into sales and bookkeeping.
class PosEventSale < ApplicationRecord
  include TenantScoped

  TENDERS = %w[cash card_terminal].freeze
  TENDER_LABELS = { 'cash' => 'Cash', 'card_terminal' => 'Card (terminal)' }.freeze

  belongs_to :pos_event
  belongs_to :user
  belongs_to :override_by, class_name: 'User', optional: true
  belongs_to :order, class_name: 'Core::Order', optional: true

  serialize :lines_json, coder: JSON
  serialize :flags_json, coder: JSON

  validates :client_sale_id, presence: true, format: { with: /\A[A-Za-z0-9-]{8,64}\z/ }, uniqueness: { scope: :pos_event_id }
  validates :tender, inclusion: { in: TENDERS }
  validates :subtotal_cents, :tax_cents, :total_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :occurred_at, presence: true
  validate do
    errors.add(:total_cents, 'must equal subtotal and tax') unless total_cents == subtotal_cents.to_i + tax_cents.to_i
    errors.add(:base, 'Sale belongs to another workspace.') unless [pos_event, user, override_by].compact.all? { |row| row.tenant_id == tenant_id }
  end

  def lines = lines_json || []
  def flags = Array(flags_json)
  def flagged? = flags.any?
  def override? = override_by_id.present?
  def tender_label = TENDER_LABELS.fetch(tender, tender.humanize)
  def units = lines.sum { |line| line['quantity'].to_i }

  def receipt
    { id: id, client_sale_id: client_sale_id, tender: tender, tender_label: tender_label, subtotal_cents: subtotal_cents,
      tax_cents: tax_cents, total_cents: total_cents, cash_received_cents: cash_received_cents, change_cents: change_cents,
      flags: flags, override: override?, lines: lines.map { |line| line.slice('name', 'quantity', 'unit_cents', 'line_cents', 'coa_url') },
      receipt_url: Rails.application.routes.url_helpers.receipt_pos_event_sale_path(pos_event_id, id) }
  end
end
