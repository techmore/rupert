# frozen_string_literal: true

# A Rupert-owned item. Native platform identities live on its links; the SKU
# and barcode here are optional search aids and are never written to platforms.
class StockItem < ApplicationRecord
  include TenantScoped

  has_many :links, class_name: 'StockItemLink', dependent: :restrict_with_exception
  has_many :balances, class_name: 'StockBalance', dependent: :restrict_with_exception
  has_many :ledger_entries, class_name: 'StockLedgerEntry', dependent: :restrict_with_exception

  validates :name, presence: true, length: { maximum: 255 }
  validates :sku, :barcode, length: { maximum: 255 }
  validates :created_by, presence: true
  before_validation do
    self.sku = sku.to_s.strip.presence
    self.barcode = barcode.to_s.strip.presence
  end

  scope :active, -> { where(active: true) }

  # Exact identifier first (a scanner wedge types the whole code), then names.
  def self.lookup(query)
    text = query.to_s.strip
    return all if text.blank?

    exact = where(sku: text).or(where(barcode: text)).or(where(id: StockItemLink.where(native_item_id: [text, *gid_forms(text)]).select(:stock_item_id)))
    return exact if exact.exists?

    pattern = "%#{sanitize_sql_like(text.downcase)}%"
    where('LOWER(name) LIKE :p OR LOWER(sku) LIKE :p OR LOWER(barcode) LIKE :p', p: pattern)
  end

  def self.gid_forms(text)
    text.match?(/\A[1-9][0-9]{0,30}\z/) ? ["gid://shopify/ProductVariant/#{text}"] : []
  end

  def label
    [name, sku.presence].compact.join(' · ')
  end
end
