# frozen_string_literal: true

class ShopifyVariant < ApplicationRecord
  include HasCuid
  include TenantScoped

  self.table_name = 'ShopifyVariant'
  self.primary_key = 'id'

  belongs_to :product,
    class_name: 'ShopifyProduct',
    foreign_key: 'productId',
    inverse_of: :variants,
    optional: true

  has_many :sku_links,
    class_name: 'SkuLink',
    foreign_key: 'shopifyVariantId',
    dependent: :nullify
  has_many :movements, class_name: 'InventoryMovement', foreign_key: 'shopifyVariantId'
  has_many :alerts, class_name: 'StockAlert', foreign_key: 'shopifyVariantId'
  has_many :levels, class_name: 'InventoryLevel', foreign_key: 'shopifyVariantId'

  scope :tracked, -> { where(tracked: true) }
  scope :current_catalog, -> { where(catalog_present: true).where(productId: ShopifyProduct.where(status: 'ACTIVE', catalog_present: true).select(:id)) }

  # Legacy rows may predate catalog presence stamps. Explicit tombstones and
  # inactive products must never be sold, even through a remembered variant ID.
  def self.warehouse_catalog(tenant_id:)
    return none if tenant_id.blank?

    products = ShopifyProduct.tenant_unscoped(tenant_id).active
    tenant_unscoped(tenant_id).where(catalog_present: [nil, true], productId: products.select(:id))
      .where(arel_table[:price].gt(0))
  end

  # Staff search the way they talk: every word must appear in the product name,
  # the variant title or the SKU ("field guide m"), or the whole text is an exact
  # SKU or barcode (a scan).
  scope :search, lambda { |q|
    text = q.to_s.strip
    return all if text.blank?

    words = text.split(/\s+/).first(6).reduce(all) do |scope, word|
      pattern = "%#{sanitize_sql_like(word)}%"
      products = ShopifyProduct.where("title LIKE ? ESCAPE '\\'", pattern).select(:id)
      scope.where("sku LIKE :p ESCAPE '\\' OR title LIKE :p ESCAPE '\\'", p: pattern).or(scope.where(productId: products))
    end
    words.or(where(sku: text)).or(where(barcode: text))
  }
end
