# frozen_string_literal: true

require 'test_helper'

class SquareSyncerTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
  end

  teardown do
    Current.tenant = nil
    Current.sync_run = nil
  end

  def stub_square_api(quantity: 7)
    SquareClient.stubs(:locations).returns([{ 'id' => 'L1', 'name' => 'Home', 'type' => 'PHYSICAL',
                                              'timezone' => 'America/New_York' }])
    SquareClient.stubs(:catalog).returns([{ itemId: 'I1', variationId: 'V1', sku: 'HERB-1', name: 'Herb 1' }])
    SquareClient.stubs(:inventory_counts).returns({ counts_by_location: { 'L1' => { 'V1' => quantity } } })
    SquareClient.stubs(:orders).returns([])
  end

  test 'mirror movements are stamped with the sync run that captured them' do
    run = SyncRun.create!(mode: 'scheduled', status: 'running', source: 'all', startedAt: Time.current)
    Current.sync_run = run
    stub_square_api

    SquareSyncer.sync!

    movement = InventoryMovement.find_by(sku: 'HERB-1')
    assert_equal run.id, movement.syncRunId
  end

  test 'movements stay untagged when no sync run is in context' do
    stub_square_api

    SquareSyncer.sync!

    movement = InventoryMovement.find_by(sku: 'HERB-1')
    assert_nil movement.syncRunId
  end

  test 'catalog ids owned by another workspace are refused before any upsert' do
    other = Tenant.create!(name: 'Other shop', subdomain: 'square-other', status: 'active')
    SquareItem.unscoped.create!(id: 'I1', name: 'Theirs', tenant_id: other.id)
    SquareVariation.unscoped.create!(id: 'V9', itemId: 'I1', sku: 'THEIRS', name: 'Theirs', tenant_id: other.id)
    stub_square_api

    error = assert_raises(SquareClient::Error) { SquareSyncer.sync! }
    assert_match(/belong to another workspace/, error.message)
    assert_equal other.id, SquareItem.unscoped.find('I1').tenant_id
    assert_equal 'Theirs', SquareItem.unscoped.find('I1').name
    assert_not SquareVariation.unscoped.exists?(id: 'V1')

    SquareItem.unscoped.where(id: 'I1').delete_all
    SquareClient.stubs(:catalog).returns([{ itemId: 'I2', variationId: 'V9', sku: 'HERB-1', name: 'Herb 1' }])
    assert_raises(SquareClient::Error) { SquareSyncer.sync! }
    assert_equal other.id, SquareVariation.unscoped.find('V9').tenant_id
  end

  test 'the same tenant re-syncing its own catalog ids is allowed' do
    stub_square_api
    SquareSyncer.sync!
    SquareSyncer.sync!
    assert_equal tenants(:default_tenant).id, SquareItem.find('I1').tenant_id
  end
end
