# frozen_string_literal: true

# A secret warehouse-sale link shared with a vendor. The token in the URL is
# the only access control — it is never listed in the app's navigation.
class WarehouseShare < ApplicationRecord
  include HasCuid
  include TenantScoped

  self.table_name = "WarehouseShare"
  self.primary_key = "id"

  has_many :tiers,
    class_name: "WarehouseTier",
    foreign_key: "shareId",
    dependent: :destroy

  before_create :generate_token

  validates :name, presence: true
  validates :token, presence: true, uniqueness: true
  validates :priceMultiplier, numericality: { greater_than_or_equal_to: 0 }

  scope :active, -> { where(status: "active") }
  scope :recent, ->(limit = 50) { order(createdAt: :desc).limit(limit) }

  def to_param
    token
  end

  def active?
    status == "active"
  end

  # Bulk tier schedule: per-vendor tiers when custom, otherwise the global
  # defaults (WarehouseTier rows with a nil shareId).
  def effective_tiers
    (use_custom_tiers? ? tiers : WarehouseTier.where(shareId: nil)).order(:minQty)
  end

  def tier_for(qty)
    effective_tiers.select { |t| qty.to_i >= t.minQty }.max_by(&:minQty)
  end

  def discount_for(qty)
    tier_for(qty)&.discountPercent.to_f
  end

  # Per-vendor price before bulk discount (list price × vendor multiplier).
  def unit_price(list_price)
    list_price.to_f * priceMultiplier.to_f
  end

  def sale_price(list_price, qty)
    (unit_price(list_price) * (1 - discount_for(qty) / 100.0)).round(2)
  end

  private

  def generate_token
    self.token ||= SecureRandom.alphanumeric(32)
  end
end
