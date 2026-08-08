# frozen_string_literal: true

class SquareVariation < ApplicationRecord
  include HasCuid
  include TenantScoped

  self.table_name = "SquareVariation"
  self.primary_key = "id"

  belongs_to :item, class_name: "SquareItem", foreign_key: "itemId",
    inverse_of: :variations, optional: true

  has_many :sku_links, class_name: "SkuLink", foreign_key: "squareVariationId",
    dependent: :nullify
  has_many :levels, class_name: "InventoryLevel", foreign_key: "squareVariationId"
  has_many :movements, class_name: "InventoryMovement", foreign_key: "squareVariationId"
  has_many :alerts, class_name: "StockAlert", foreign_key: "squareVariationId"

  scope :search, ->(q) {
    return all if q.blank?
    where(sku: q).or(where("sku LIKE ?", "%#{q}%")).or(where("name LIKE ?", "%#{q}%"))
  }
end
