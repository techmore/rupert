class AddFeaturedImageUrlToShopifyProduct < ActiveRecord::Migration[8.1]
  def change
    add_column :"ShopifyProduct", :featuredImageUrl, :string
  end
end
