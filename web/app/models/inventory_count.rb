# frozen_string_literal: true

# A manual physical inventory worksheet. The counter records the actual on-hand
# quantity per SKU; once a supervisor approves it, the counted quantities
# override the system's computed totals (see #apply_override!).
class InventoryCount < ApplicationRecord
  include HasCuid
  include TenantScoped
  include AASM

  self.table_name = "InventoryCount"
  self.primary_key = "id"

  has_many :items, class_name: "InventoryCountItem", foreign_key: "countId",
    dependent: :destroy, inverse_of: :count
  belongs_to :location, class_name: "Location", foreign_key: "locationId", optional: true

  validates :countedAt, presence: true

  scope :recent, ->(limit = 30) { order(countedAt: :desc).limit(limit) }
  scope :by_status, ->(status) { status.present? ? where(status: status) : all }

  aasm column: "status", no_direct_assignment: true do
    state :draft, initial: true
    state :pending
    state :approved
    state :rejected

    event :submit do
      transitions from: :draft, to: :pending
    end
    event :approve do
      transitions from: :pending, to: :approved
    end
    event :reject do
      transitions from: :pending, to: :rejected
    end
    event :reopen do
      transitions from: :rejected, to: :draft
    end
  end

  def total_quantity
    items.sum(:quantity)
  end

  def applied_items
    items.where(applied: true)
  end

  # Freeze the system's current totals so the count can be compared and later
  # applied even if the SKU link changes. Called when the count is submitted.
  def snapshot_previous!
    items.find_each do |item|
      link = SkuLink.find_by(sku: item.sku)
      item.update!(
        shopifyVariantId: link&.shopifyVariantId,
        squareVariationId: link&.squareVariationId,
        previousQuantity: link&.shopifyVariantId.presence ?
          InventoryLevel.total_for_variant(link.shopifyVariantId) : 0
      )
    end
    self
  end

  # Applies the counted quantities as an override of current totals. Called once
  # the count is approved. For each line, adjusts a level so the variant's
  # computed total equals the counted quantity and records the movement.
  def apply_override!(actor: "user")
    return false unless approved?

    items.find_each do |item|
      applied = false
      applied |= adjust_source!(item, source: "shopify",
        variant_column: :shopifyVariantId, actor: actor) if item.shopifyVariantId.present?
      applied |= adjust_source!(item, source: "square",
        variant_column: :squareVariationId, actor: actor) if item.squareVariationId.present?
      item.update!(applied: applied) if applied
    end
    update!(appliedAt: Time.current)
    true
  end

  private

  def adjust_source!(item, source:, variant_column:, actor:)
    current_total = if source == "shopify"
                      InventoryLevel.total_for_variant(item.shopifyVariantId)
                    else
                      InventoryLevel.total_for_variation(item.squareVariationId)
                    end
    delta = item.quantity - current_total
    return false if delta.zero?

    level = InventoryLevel.find_or_initialize_by(
      source: source, locationId: override_location(source, variant_column, item),
      variant_column => item[variant_column]
    )
    before = level.quantity.to_i
    after = [before + delta, 0].max
    level.quantity = after
    level.available = after
    level.save!

    InventoryMovement.create!(
      source: source, sku: item.sku, direction: delta.positive? ? "in" : "out",
      delta: delta.abs, quantityBefore: before, quantityAfter: after,
      reason: "manual count override", reference: "count:#{id}", actor: actor,
      variant_column => item[variant_column]
    )
    true
  end

  def override_location(source, variant_column, item)
    return locationId if locationId.present?

    existing = InventoryLevel.where(source: source, variant_column => item[variant_column])
      .order(updatedAt: :desc).first
    return existing.locationId if existing

    Location.create!(
      source: source, externalId: "manual-override-#{source}",
      name: "Manual override", active: true
    ).id
  end
end
