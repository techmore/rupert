# frozen_string_literal: true

require 'test_helper'

# The item page: real name instead of "Default Title", centered photo and name, cost, margin and stock everywhere.
class ItemPageTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    post login_path, params: { email: users(:regular_user).email, password: 'password' }
    @product = ShopifyProduct.create!(id: 'item-tea', title: 'Herbal Tea', status: 'ACTIVE', featuredImageUrl: 'https://cdn.example.test/tea.png',
      vendor: 'Leaf Farms', productType: 'Tea', tags: 'loose, calm')
    @variant = ShopifyVariant.create!(id: 'gid://shopify/ProductVariant/item-1', product: @product, title: 'Default Title', sku: 'TEA-50',
      barcode: '0123', price: 20.0, tracked: true, inventoryQuantity: 4)
    store = Location.create!(source: 'ctrax', externalId: 'item/1', name: 'Main Street')
    CtraxStockSnapshot.create!(location: store, api_origin: 'https://fixture.api.cannatrax.net', store_id: '1', captured_at: Time.current,
      records_json: [{ 'id' => 'ct-tea', 'sku' => 'TEA-50', 'name' => 'Herbal Tea 50g', 'quantity' => '6', 'manage_stock' => true, 'cost_cents' => 600 }])
  end

  teardown { Current.reset }

  test 'a single-variant item shows its product name, centered photo, price, cost and margin, not Default Title' do
    get shopify_variant_path(@variant)
    assert_response :success
    assert_select 'h1', 'Herbal Tea'
    assert_select 'title', /Herbal Tea/
    assert_not_includes response.body, 'Default Title'
    assert_select '.item-hero .item-hero-image img[src="https://cdn.example.test/tea.png"]'
    assert_select '.item-hero-facts', /Price.*\$20\.00/m
    assert_select '.item-hero-facts', /Cost of goods.*\$6\.00.*As entered in C-Trax \(same sku\)/m
    assert_select '.item-hero-facts', /Margin per unit.*\$14\.00 \(70\.0%\)/m
    assert_select 'section[aria-labelledby=item-source-title]', /Leaf Farms.*Tea.*Herbal Tea 50g/m
    assert_select 'section[aria-labelledby=item-stock-title] tr', /C-Trax.*Main Street.*6/m
  end

  test 'cost stays unknown when the C-Trax item has none, and a variant option is shown under the name' do
    CtraxStockSnapshot.sole.update!(records_json: [{ 'id' => 'ct-tea', 'sku' => 'TEA-50', 'name' => 'Herbal Tea 50g', 'quantity' => '6', 'manage_stock' => true }])
    @variant.update!(title: '50g')
    get shopify_variant_path(@variant)
    assert_select 'h1', 'Herbal Tea · 50g'
    assert_select '.item-hero-option', '50g'
    assert_select '.item-hero-facts', /Cost of goods.*Unknown.*Not entered in C-Trax/m
    assert_select '.item-hero-facts', /Margin per unit.*Unknown/m
  end

  test 'ItemProfile drops Shopify and Square placeholder titles' do
    assert_equal 'Herbal Tea', ItemProfile.display_name(@variant)
    @variant.title = 'Regular'
    assert_equal 'Herbal Tea', ItemProfile.display_name(@variant)
    @variant.title = '100g'
    assert_equal 'Herbal Tea · 100g', ItemProfile.display_name(@variant)
  end

  test 'a cost entered in Rupert wins over C-Trax, is logged, and removing it falls back to C-Trax' do
    get shopify_variant_path(@variant)
    assert_select 'details.item-cost-edit summary', 'Add cost'
    patch cost_shopify_variant_path(@variant), params: { cost: '$7.50' }
    assert_redirected_to shopify_variant_path(@variant)
    assert_equal 750, ItemCost.sole.cost_cents
    assert_equal users(:regular_user), ItemCost.sole.updated_by
    assert_equal 'test-tenant-default', ItemCost.sole.tenant_id
    assert_match(/\$7\.50/, ActivityLog.find_by!(action: 'item_cost_set').details)
    follow_redirect!
    assert_select '.item-hero-facts', /Cost of goods.*\$7\.50.*Entered in Rupert by .+ on [A-Z][a-z]{2} \d+, \d{4}/m
    assert_select '.item-hero-facts', /Margin per unit.*\$12\.50 \(62\.5%\)/m
    assert_select 'details.item-cost-edit summary', 'Edit cost'
    assert_select 'input#item-cost[value="7.50"]'

    patch cost_shopify_variant_path(@variant), params: { cost: '8' }
    assert_equal 800, ItemCost.sole.cost_cents
    assert_match(/\$7\.50 -> \$8\.00/, ActivityLog.where(action: 'item_cost_set').order(:id).last.details)

    patch cost_shopify_variant_path(@variant), params: { cost: '8', remove: '1' }
    assert_empty ItemCost.all
    assert ActivityLog.exists?(action: 'item_cost_removed')
    follow_redirect!
    assert_select '.item-hero-facts', /Cost of goods.*\$6\.00.*As entered in C-Trax/m
  end

  test 'saving a blank cost removes it, and an item with no C-Trax cost goes back to Unknown, never zero' do
    CtraxStockSnapshot.delete_all
    ItemCost.create!(shopify_variant_id: @variant.id, cost_cents: 500, updated_by: users(:regular_user))
    patch cost_shopify_variant_path(@variant), params: { cost: '  ' }
    assert_empty ItemCost.all
    follow_redirect!
    assert_select '.item-hero-facts', /Cost of goods.*Unknown.*Not paired with a C-Trax item yet/m
    assert_select '.item-hero-facts', /Margin per unit.*Unknown/m
    assert_not_includes css_select('.item-hero-facts').text, '$0.00'
  end

  test 'a zero cost entered in Rupert is shown as zero, and bad amounts are refused' do
    patch cost_shopify_variant_path(@variant), params: { cost: 'abc' }
    assert_match(/amount/, flash[:alert])
    patch cost_shopify_variant_path(@variant), params: { cost: '-2' }
    assert_empty ItemCost.all
    patch cost_shopify_variant_path(@variant), params: { cost: '0' }
    assert_equal 0, ItemCost.sole.cost_cents
    profile = ItemProfile.new(@variant.reload)
    assert_equal :rupert, profile.cost_source
    assert_equal 2000, profile.margin_cents
  end

  test 'readers see the cost but no form, and cannot change it' do
    delete logout_path
    reader = User.create!(tenant: tenants(:default_tenant), email: 'cost-reader@example.com', name: 'Reader', role: 'reader', password: 'password123')
    post login_path, params: { email: reader.email, password: 'password123' }
    get shopify_variant_path(@variant)
    assert_response :success
    assert_select '.item-hero-facts', /\$6\.00/
    assert_select 'details.item-cost-edit', count: 0
    patch cost_shopify_variant_path(@variant), params: { cost: '1.00' }
    assert_equal "You don't have permission to do that.", flash[:alert]
    assert_empty ItemCost.all
  end
end
