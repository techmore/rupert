# frozen_string_literal: true

class SquareVariation < ApplicationRecord
  include HasCuid
  include TenantScoped

  self.table_name = 'SquareVariation'
  self.primary_key = 'id'

  belongs_to :item,
    class_name: 'SquareItem',
    foreign_key: 'itemId',
    inverse_of: :variations,
    optional: true

  has_many :sku_links,
    class_name: 'SkuLink',
    foreign_key: 'squareVariationId',
    dependent: :nullify
  has_many :levels, class_name: 'InventoryLevel', foreign_key: 'squareVariationId'
  has_many :movements, class_name: 'InventoryMovement', foreign_key: 'squareVariationId'
  has_many :alerts, class_name: 'StockAlert', foreign_key: 'squareVariationId'

  # Every word in the item name, variation name or SKU, or an exact SKU (as ShopifyVariant.search).
  scope :search, lambda { |q|
    text = q.to_s.strip
    return all if text.blank?

    words = text.split(/\s+/).first(6).reduce(all) do |scope, word|
      pattern = "%#{sanitize_sql_like(word)}%"
      items = SquareItem.where("name LIKE ? ESCAPE '\\'", pattern).select(:id)
      scope.where("sku LIKE :p ESCAPE '\\' OR name LIKE :p ESCAPE '\\'", p: pattern).or(scope.where(itemId: items))
    end
    words.or(where(sku: text))
  }

  def name_with_sku
    sku.present? ? "#{name} (#{sku})" : name
  end
end
