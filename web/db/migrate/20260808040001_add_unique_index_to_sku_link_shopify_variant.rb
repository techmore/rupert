class AddUniqueIndexToSkuLinkShopifyVariant < ActiveRecord::Migration[7.1]
  def change
    remove_index "SkuLink", ["shopifyVariantId"] if index_exists?("SkuLink", ["shopifyVariantId"])
    add_index "SkuLink", ["shopifyVariantId"], unique: true
  end
end
