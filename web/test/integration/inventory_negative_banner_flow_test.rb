# frozen_string_literal: true

require "test_helper"

class InventoryNegativeBannerFlowTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: "Neg Co", subdomain: "negco#{SecureRandom.hex(4)}")
    @admin = User.create!(email: "neg-admin@example.com", password: "password123", role: "admin", name: "Admin", tenant_id: @tenant.id)
    post login_path, params: { email: @admin.email, password: "password123" }
    Current.tenant = @tenant
  end

  teardown do
    Current.tenant = nil
  end

  test "inventory shows the negative-count banner when negatives exist" do
    location = Location.create!(source: "square", externalId: "LOC", name: "Home", tenant_id: @tenant.id)
    SquareVariation.create!(id: "vneg", itemId: "i", sku: "NEG", name: "Neg", tenant_id: @tenant.id)
    InventoryLevel.create!(source: "square", locationId: location.id, squareVariationId: "vneg", quantity: -3, available: -3, tenant_id: @tenant.id)

    get inventory_index_path
    assert_response :success
    assert_includes response.body, "negative counts"
    assert_includes response.body, "NEG"
  end

  test "inventory hides the banner when nothing is negative" do
    get inventory_index_path
    assert_response :success
    assert_not_includes response.body, "Inventory went negative"
  end

  test "an admin can fix a negative item" do
    location = Location.create!(source: "square", externalId: "LOC", name: "Home", tenant_id: @tenant.id)
    SquareVariation.create!(id: "vneg", itemId: "i", sku: "NEG", name: "Neg", tenant_id: @tenant.id)
    InventoryLevel.create!(source: "square", locationId: location.id, squareVariationId: "vneg", quantity: -3, available: -3, tenant_id: @tenant.id)
    SquareClient.stubs(:request).returns({})

    post fix_negative_inventory_index_path, params: { source: "square", id: "vneg" }
    assert_redirected_to(inventory_index_path)
    assert_equal 0, InventoryLevel.find_by(squareVariationId: "vneg").quantity
  end
end
