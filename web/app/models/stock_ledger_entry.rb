# frozen_string_literal: true

# Append-only Rupert stock movement. Rows are written by MasterStock::Ledger
# and never updated or deleted through the application.
class StockLedgerEntry < ApplicationRecord
  include TenantScoped

  KINDS = %w[count receive adjust transfer_out transfer_in sale return].freeze
  STAFF_KINDS = %w[count receive adjust transfer].freeze
  REASONS = {
    'damaged' => 'Damaged', 'expired' => 'Expired', 'theft' => 'Theft or loss', 'sample' => 'Sample or staff use',
    'vendor_return' => 'Returned to vendor', 'found' => 'Found stock', 'correction' => 'Correction', 'other' => 'Other'
  }.freeze

  belongs_to :stock_item
  belongs_to :stock_site

  validates :kind, inclusion: { in: KINDS }
  validates :origin, inclusion: { in: %w[rupert shopify ctrax square] }
  validates :reason, inclusion: { in: REASONS.keys }, allow_nil: true
  validates :actor, :request_token, :payload_digest, presence: true
  validates :quantity_after, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  def readonly?
    persisted?
  end

  def before_destroy_guard
    raise ActiveRecord::ReadOnlyRecord
  end
  before_destroy :before_destroy_guard

  def kind_label
    { 'count' => 'Count', 'receive' => 'Received', 'adjust' => 'Adjusted', 'transfer_out' => 'Transfer out',
      'transfer_in' => 'Transfer in', 'sale' => 'Sale', 'return' => 'Return' }.fetch(kind, kind.humanize)
  end
end
