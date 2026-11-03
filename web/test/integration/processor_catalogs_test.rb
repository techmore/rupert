# frozen_string_literal: true

require 'test_helper'

class ProcessorCatalogsIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @location = Location.create!(source: 'ctrax', externalId: 'catalog-fixture/1', name: 'Catalog fixture')
    CtraxStockSnapshot.create!(location: @location, api_origin: 'https://fixture.api.cannatrax.net', store_id: '1', captured_at: Time.current,
      records_json: [
        { 'id' => '1', 'name' => 'CBD tincture 3500mg', 'sku' => 'HH-CBD-1', 'category' => 'CBD Tinctures', 'listed' => true },
        { 'id' => '2', 'name' => 'THCA flower 3.5g', 'sku' => 'HH-THCA-1', 'category' => 'THCA Flower', 'listed' => true }
      ])
    post login_path, params: { email: @user.email, password: 'password' }
  end
  teardown { Current.reset }

  test 'owner records approval, adds approved entries, enforces and sees refused products' do
    get processor_catalogs_path
    assert_response :success
    assert_select 'section#authorize_net', /Not enforced/

    patch processor_catalog_path('authorize_net'), params: { processor_catalog: { enforced: '1', approval_reference: '' } }
    assert_match(/Approval reference is required before enforcing/, flash[:alert])
    assert_not ProcessorCatalog.find_by(processor: 'authorize_net')&.enforced

    post processor_catalog_entries_path('authorize_net'), params: { kind: 'category', values: "CBD Tinctures\ncbd tinctures\nPet CBD" }
    assert_equal 2, ProcessorCatalog.find_by!(processor: 'authorize_net').entries.count
    assert_match(/2 added/, flash[:notice])

    patch processor_catalog_path('authorize_net'), params: { processor_catalog: { enforced: '1', approval_reference: 'ISO approval email 2026-11-20' } }
    catalog = ProcessorCatalog.find_by!(processor: 'authorize_net')
    assert catalog.enforced
    assert_equal @user.id, catalog.approved_by_id
    assert ActivityLog.where(action: 'processor_catalog_saved').exists?

    get processor_catalogs_path
    assert_select 'section#authorize_net details summary', /1 of 2 current register products would be refused/
    assert_select 'section#authorize_net details li', /THCA flower 3.5g \(SKU HH-THCA-1\)/

    entry = catalog.entries.find_by!(normalized_value: 'pet cbd')
    delete processor_catalog_entry_path('authorize_net', entry.id)
    assert_equal 1, catalog.entries.count
    assert ActivityLog.where(action: 'processor_catalog_entry_removed').exists?
  end

  test 'unknown processor and users without setup permissions are refused' do
    post processor_catalog_entries_path('square'), params: { kind: 'sku', values: 'X' }
    assert_response :not_found
    @user.update!(role: 'employee')
    get processor_catalogs_path
    assert_not_equal 200, response.status
  end
end
