# frozen_string_literal: true

require "test_helper"

class SizeDeriverTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @family = SizeFamily.create!(name: "Test Hash", mode: "approval", tenant_id: Current.tenant_id)
    @m35 = @family.members.create!(sku: "thash35", grams: 3.5, tenant_id: Current.tenant_id)
    @m7 = @family.members.create!(sku: "thash7", grams: 7, tenant_id: Current.tenant_id)
  end

  teardown do
    Current.tenant = nil
  end

  test "build computes floor(root / grams) targets" do
    @family.update!(base_grams: 100, sales_watermark: Time.current)
    SquareClient.stubs(:configured?).returns(false)

    result = SizeDeriver.build(@family)
    assert_equal 100.0, result[:root_grams]
    assert_equal 0.0, result[:grams_sold]
    targets = result[:proposals].to_h { |p| [p[:member].sku, p[:target]] }
    assert_equal 28, targets["thash35"]
    assert_equal 14, targets["thash7"]
  end

  test "build folds sales since the watermark into root grams" do
    @family.update!(base_grams: 100, sales_watermark: Time.current - 1.hour)
    @m35.update!(square_variation_id: "v35")
    @m7.update!(square_variation_id: "v7")
    SquareClient.stubs(:configured?).returns(true)
    SquareClient.stubs(:locations).returns([{ "id" => "L1" }])
    SquareClient.stubs(:orders).returns([
      { "line_items" => [{ "catalog_object_id" => "v35", "quantity" => 2 }] },
      { "line_items" => [{ "catalog_object_id" => "v7", "quantity" => 1 }] },
    ])

    result = SizeDeriver.build(@family)
    assert_in_delta 100 - (2 * 3.5) - 7, result[:root_grams], 0.01
    refute_nil @family.reload.sales_watermark
  end

  test "root grams floor at zero" do
    @family.update!(base_grams: 5, sales_watermark: Time.current - 1.hour)
    @m35.update!(square_variation_id: "v35")
    SquareClient.stubs(:configured?).returns(true)
    SquareClient.stubs(:locations).returns([{ "id" => "L1" }])
    SquareClient.stubs(:orders).returns([
      { "line_items" => [{ "catalog_object_id" => "v35", "quantity" => 4 }] },
    ])

    result = SizeDeriver.build(@family)
    assert_equal 0.0, result[:root_grams]
    assert result[:proposals].all? { |p| p[:target] == 0 }
  end

  test "approval mode records pending changes only when a target differs" do
    @family.update!(base_grams: 100, sales_watermark: Time.current)
    SquareClient.stubs(:configured?).returns(false)
    SquareVariation.create!(id: "v35", itemId: "i1", sku: "thash35", name: "3.5 Grams", tenant_id: Current.tenant_id)
    SquareVariation.create!(id: "v7", itemId: "i1", sku: "thash7", name: "7 Grams", tenant_id: Current.tenant_id)
    @m35.update!(square_variation_id: "v35")
    @m7.update!(square_variation_id: "v7")
    InventoryLevel.create!(source: "square", locationId: "L1", squareVariationId: "v35", quantity: 28, tenant_id: Current.tenant_id)
    InventoryLevel.create!(source: "square", locationId: "L1", squareVariationId: "v7", quantity: 5, tenant_id: Current.tenant_id)

    result = SizeDeriver.process(@family)
    assert_equal 1, result[:pending]
    assert_equal ["thash7"], @family.size_changes.pending.map(&:sku)
  end

  test "auto mode applies targets to Square and journals movements" do
    @family.update!(mode: "auto", base_grams: 100, sales_watermark: Time.current)
    SquareClient.stubs(:configured?).returns(false)
    @m35.update!(square_variation_id: "v35")
    @m7.update!(square_variation_id: "v7")
    home = Location.create!(source: "square", externalId: "HOME", name: "Home")
    SquareSyncer.stubs(:primary_location_id).returns(home)
    SquareClient.stubs(:request).returns({})

    result = SizeDeriver.process(@family)
    assert_equal 2, result[:applied]
    assert_equal 0, result[:failed]
    assert @family.size_changes.where(status: "applied").count >= 2
    assert InventoryMovement.where(source: "size-derive").count >= 2
  end

  test "apply_change! fails cleanly when Square rejects" do
    @family.update!(mode: "auto", base_grams: 100, sales_watermark: Time.current)
    SquareClient.stubs(:configured?).returns(false)
    @m35.update!(square_variation_id: "v35")
    home = Location.create!(source: "square", externalId: "HOME", name: "Home")
    SquareSyncer.stubs(:primary_location_id).returns(home)
    SquareClient.stubs(:request).raises(SquareClient::Error, "boom")

    change = SizeChange.create!(family_id: @family.id, sku: "thash35", grams: 3.5, root_grams: 100,
      target_quantity: 28, square_variation_id: "v35", tenant_id: Current.tenant_id, mode: "auto")
    refute SizeDeriver.apply_change!(change)
    assert_equal "failed", change.reload.status
    assert_includes change.error, "boom"
  end
end
