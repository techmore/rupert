# frozen_string_literal: true

# A server-side shopping cart for a warehouse-sale vendor link. Anonymous
# visitors are keyed by a random token stored in a signed cookie, so the cart
# survives reloads without any login. Prices are always computed server-side
# (never trusted from the browser) via WarehouseShare#sale_price.
class WarehouseCart < ApplicationRecord
  STATUSES = ["open", "checked_out"].freeze

  belongs_to :share, class_name: "WarehouseShare", foreign_key: :share_id
  has_many :items,
    class_name: "WarehouseCartItem",
    foreign_key: :cart_id,
    dependent: :destroy

  validates :token, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  def checked_out?
    status == "checked_out"
  end

  def add_item!(variant, quantity: 1)
    quantity = quantity.to_i.clamp(1, WarehouseCartItem::MAX_QUANTITY)
    item = items.find_or_initialize_by(variant_id: variant.id)
    item.tenant_id = tenant_id
    item.share_id = share_id
    item.sku = variant.sku
    item.title = [variant.product&.title, variant.title].compact.join(" · ")
    item.quantity = (item.quantity.to_i + quantity).clamp(1, WarehouseCartItem::MAX_QUANTITY)
    item.assign_price!(share, variant)
    item.save!
    item
  end

  # Update (or remove when <= 0) an existing line, keeping prices in sync with
  # the current quantity.
  def set_quantity!(item_id, quantity)
    item = items.find(item_id)
    if quantity.to_i <= 0
      item.destroy!
    else
      item.quantity = quantity.to_i.clamp(1, WarehouseCartItem::MAX_QUANTITY)
      item.assign_price!(share, item.variant)
      item.save!
    end
  end

  def total_cents
    items.sum(:line_cents)
  end

  def item_count
    items.sum(:quantity)
  end

  def mark_checked_out!
    update!(status: "checked_out")
  end
end
