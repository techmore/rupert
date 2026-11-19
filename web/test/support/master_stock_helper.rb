# frozen_string_literal: true

# Builders for Rupert-owned stock tests: a workspace with an inventory user,
# Shopify and C-Trax locations and a mapped Rupert site.
module MasterStockHelper
  def master_stock_workspace!
    @tenant = create_workspace('Master stock')
    @user = User.create!(email: "stock-#{SecureRandom.hex(3)}@example.com", password: 'password123', role: 'inventory_employee', tenant: @tenant)
    @admin = User.create!(email: "stock-admin-#{SecureRandom.hex(3)}@example.com", password: 'password123', role: 'admin', tenant: @tenant)
    @shopify_location = Location.create!(source: 'shopify', externalId: 'gid://shopify/Location/11', name: 'Main (Shopify)', active: true)
    @ctrax_location = Location.create!(source: 'ctrax', externalId: 'store.api.cannatrax.net/7', name: 'Main (C-Trax)', active: true)
    @site = StockSite.create!(name: 'Main store', shopify_location_id: @shopify_location.id, ctrax_location_id: @ctrax_location.id)
    @other_site = StockSite.create!(name: 'Second store')
    product = ShopifyProduct.create!(id: "gid://shopify/Product/#{SecureRandom.random_number(10**9) + 1}", title: 'Gummies', status: 'ACTIVE')
    @variant = ShopifyVariant.create!(id: 'gid://shopify/ProductVariant/501', productId: product.id, sku: 'GUM-10', title: '10 pack',
      inventoryItemId: 'gid://shopify/InventoryItem/901', tracked: true, catalog_present: true)
    @item = StockItem.create!(name: 'Gummies 10 pack', sku: 'GUM-10', created_by: @admin.email)
  end

  def ledger(actor = @user) = MasterStock::Ledger.new(actor: actor)

  def record(kind, quantity, site: @site, item: @item, token: SecureRandom.uuid, **options)
    ledger.record(kind: kind, item: item, site: site, quantity: quantity, token: token, **options)
  end

  def shopify_snapshot!(on_hand:, at: 5.minutes.ago, variant: @variant)
    ShopifyStockSnapshot.create!(location: @shopify_location, shop_domain: 'example.myshopify.com', captured_at: at,
      records_json: [{ 'id' => variant.id, 'inventory_item_id' => variant.inventoryItemId, 'available' => on_hand - 1, 'on_hand' => on_hand, 'committed' => 1 }])
  end

  def ctrax_snapshot!(records, at: 5.minutes.ago)
    CtraxStockSnapshot.create!(location: @ctrax_location, api_origin: 'https://store.api.cannatrax.net', store_id: '7', captured_at: at, records_json: records)
  end
end
