# frozen_string_literal: true

class InventoryMovement < ApplicationRecord
  include HasCuid
  include TenantScoped

  self.table_name = "InventoryMovement"
  self.primary_key = "id"

  belongs_to :shopify_variant,
    class_name: "ShopifyVariant",
    foreign_key: "shopifyVariantId",
    optional: true
  belongs_to :square_variation,
    class_name: "SquareVariation",
    foreign_key: "squareVariationId",
    optional: true
  belongs_to :sync_run,
    class_name: "SyncRun",
    foreign_key: "syncRunId",
    optional: true

  scope :recent, ->(limit = 25) { order(createdAt: :desc).limit(limit) }
  scope :by_source, ->(source) { where(source: source) }
end
