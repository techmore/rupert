# frozen_string_literal: true

require "test_helper"

class SquareSyncerTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
  end

  teardown do
    Current.tenant = nil
    Current.sync_run = nil
  end

  def stub_square_api(quantity: 7)
    SquareClient.stubs(:locations).returns([{ "id" => "L1", "name" => "Home", "type" => "PHYSICAL", "timezone" => "America/New_York" }])
    SquareClient.stubs(:catalog).returns([{ itemId: "I1", variationId: "V1", sku: "HERB-1", name: "Herb 1" }])
    SquareClient.stubs(:inventory_counts).returns({ counts_by_location: { "L1" => { "V1" => quantity } } })
    SquareClient.stubs(:orders).returns([])
  end

  test "mirror movements are stamped with the sync run that captured them" do
    run = SyncRun.create!(mode: "scheduled", status: "running", source: "all", startedAt: Time.current)
    Current.sync_run = run
    stub_square_api

    SquareSyncer.sync!

    movement = InventoryMovement.find_by(sku: "HERB-1")
    assert_equal run.id, movement.syncRunId
  end

  test "movements stay untagged when no sync run is in context" do
    stub_square_api

    SquareSyncer.sync!

    movement = InventoryMovement.find_by(sku: "HERB-1")
    assert_nil movement.syncRunId
  end
end
