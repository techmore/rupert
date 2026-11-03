# frozen_string_literal: true

require 'test_helper'
require_relative '../support/compliance_fixtures'

# F70 through the browser: the owner approves the catalog and locks the register,
# the cashier sees only approved items, a blocked card sale needs a manager PIN,
# and an event runs from setup to reconciliation.
class ComplianceGuardrailsTest < ActionDispatch::IntegrationTest
  include ComplianceFixtures

  setup do
    Current.tenant = tenants(:default_tenant)
    Finance::ChartOfAccounts.seed!
    @owner = users(:regular_user)
    @location = compliance_store(name: 'Newtown')
    @snapshot = CtraxStockSnapshot.find_by!(location: @location)
    @manager = manager_with_pin
    PosConnection.create!(provider: 'ctrax', vendor_approved: true, credentials_json: { api_url: @snapshot.api_origin, api_username: 'f', api_password: 'p' }.to_json)
    PosSetting.create!(location: @location, cash_enabled: true)
    @register = Sales::PosSession.create!(location: @location, user: @owner, name: 'Front', opened_at: Time.current)
    Ctrax::StockSync.stubs(:call).returns(stores: 1, variants: 1)
  end
  teardown { Current.reset }

  test 'owner approves items, adds a COA and locks the register; every change is in the audit log' do
    sign_in @owner
    category = ComplianceCategory.create!(name: 'CBD tinctures (THC free)', card_eligible: true)
    get compliance_path(location_id: @location.id, filter: 'unapproved')
    assert_response :success
    assert_select 'a[href=?]', new_compliance_catalog_item_path(location_id: @location.id, variant_id: '11'), 'Approve'

    post compliance_catalog_items_path(location_id: @location.id, variant_id: '11'),
      params: { compliance_catalog_item: { compliant_name: 'Pain Relief Drops', compliance_category_id: category.id, card_eligible: '1' } }
    assert_response :unprocessable_entity
    assert_includes response.body, 'health or marijuana claim'

    post compliance_catalog_items_path(location_id: @location.id, variant_id: '11'),
      params: { compliance_catalog_item: { compliant_name: 'Broad Spectrum Hemp Extract 1000mg', receipt_name: 'Hemp Extract 1000mg', compliance_category_id: category.id,
                                           card_eligible: '1', cash_eligible: '1', age_restricted: '1', coa_required: '1', approved_price: '40.00', thc_mg_per_container: '0' } }
    item = ComplianceCatalogItem.sole
    assert_redirected_to compliance_path(location_id: @location.id, q: item.compliant_name)
    assert_equal [4000, @owner.id], [item.approved_price_cents, item.approved_by_id]

    post compliance_catalog_item_certificates_path(item), params: { certificate_of_analysis: { lab_name: 'ACS Labs', report_identifier: 'R-1',
      tested_on: 20.days.ago.to_date.iso8601, document_url: 'http://insecure.example.com/coa.pdf' } }
    assert_response :unprocessable_entity
    post compliance_catalog_item_certificates_path(item), params: { certificate_of_analysis: { lab_name: 'ACS Labs', report_identifier: 'R-1',
      tested_on: 20.days.ago.to_date.iso8601, document_url: 'https://labs.example.com/r1.pdf' } }
    assert_redirected_to edit_compliance_catalog_item_path(item)

    patch compliance_policy_path(@location.id), params: { compliance_policy: { locked_catalog: '1', coa_max_age_days: '365' } }
    assert CompliancePolicy.find_by!(location: @location).locked_catalog

    get compliance_path(tab: 'audit')
    assert_response :success
    %w[catalog_item_approved coa_added policy_changed].each { |action| assert_select "tr[data-compliance-action=#{action}]" }
    %w[certificates categories exceptions].each do |tab|
      get compliance_path(tab: tab, location_id: @location.id)
      assert_response :success
    end
  end

  test 'staff without owner rights cannot change the catalog; POS-only staff cannot open the compliance pages' do
    employee = cashier
    sign_in employee
    get compliance_path
    assert_response :redirect
    post compliance_categories_path, params: { compliance_category: { name: 'Anything', card_eligible: '1' } }
    assert_response :redirect
    assert_empty ComplianceCategory.all
    assert_empty ComplianceEvent.all
  end

  test 'a locked register shows approved items only, by compliant name, and blocks card on a cash-only item until a manager PIN' do
    approve!(@location, '11', name: 'Broad Spectrum Hemp Extract 1000mg', category: card_category, receipt_name: 'Hemp Extract 1000mg')
    approve!(@location, '22', name: 'Hemp Flower 3.5g', category: cash_category, card: false)
    CompliancePolicy.create!(location: @location, locked_catalog: true)
    Ctrax::CatalogImages.any_instance.stubs(:url).returns('https://cdn.shopify.com/s/files/fixture.png')
    sign_in @owner

    get ctrax_pos_path(location_id: @location.id)
    assert_response :success
    assert_includes response.body, 'Hemp Extract 1000mg'
    assert_not_includes response.body, 'Mystery Item'
    assert_not_includes response.body, 'THCA Flower 3.5g'
    assert_select '[data-compliance-flag="cash-only"]', 1

    display = PosDisplaySession.create!(user: @owner, location: @location)
    post quote_ctrax_pos_path(@location.id, display_id: display.id), params: { items: [{ variant_id: '33', quantity: 1 }] }, as: :json
    assert_response :unprocessable_entity
    assert_match(/approved catalog/, response.parsed_body['error'])

    post quote_ctrax_pos_path(@location.id, display_id: display.id), params: { items: [{ variant_id: '22', quantity: 1 }] }, as: :json
    assert_response :success
    assert_equal 'Hemp Flower 3.5g', response.parsed_body['lines'].first['title']
    display.reload.choose_tip!(revision: display.cart_revision, choice: 'none')

    get ctrax_pos_path(location_id: @location.id, display_id: display.id)
    assert_select '[data-compliance-checks] input[name=id_checked]'
    assert_select '[data-compliance-checks] select[name=override_user_id] option', text: @manager.display_name

    post pos_checkouts_path, params: { display_id: display.id, tender: 'card_a920', register_id: @register.id, id_checked: true }, as: :json
    assert_response :unprocessable_entity
    body = response.parsed_body
    assert_equal [false, true], body['compliance'].values_at('allowed', 'overridable')
    assert_equal ['card_ineligible'], body['compliance']['issues'].map { |i| i['code'] }

    post pos_checkouts_path, params: { display_id: display.id, tender: 'card_a920', register_id: @register.id, id_checked: true,
      override_user_id: @manager.id, override_pin: '1111', override_reason: 'Owner approved card' }, as: :json
    assert_response :unprocessable_entity
    assert_match(/PIN is not right/, response.parsed_body['error'])

    post pos_checkouts_path, params: { display_id: display.id, tender: 'card_a920', register_id: @register.id, id_checked: true,
      override_user_id: @manager.id, override_pin: '4321', override_reason: 'Owner approved card' }, as: :json
    assert_response :success
    assert_equal 'paid', response.parsed_body['status']
    checkout = PosCheckout.sole
    get pos_checkout_path(checkout)
    assert_select 'dt', 'Manager override'
    assert_equal %w[sale_blocked override_refused override_granted], ComplianceEvent.order(:id).pluck(:action)
  end

  test 'an event runs from setup through the register, offline-safe sales, receipt QR and reconciliation' do
    approve!(@location, '11', name: 'Broad Spectrum Hemp Extract 1000mg', category: card_category, receipt_name: 'Hemp Extract 1000mg', approved_price_cents: 4000)
    flower = approve!(@location, '22', name: 'Hemp Flower 3.5g', category: cash_category, card: false)
    seller = cashier
    sign_in @owner

    post pos_events_path, params: { pos_event: { name: 'Bucks County Wellness Fair', venue: 'Fairgrounds', location_id: @location.id,
      starts_on: Date.current.iso8601, ends_on: Date.current.iso8601, tax_rate: '6', opening_float: '100', staff_user_ids: [seller.id] } }
    event = PosEvent.sole
    assert_redirected_to pos_event_path(event)
    assert_equal [600, 10_000, [seller.id]], [event.tax_rate_bps, event.opening_float_cents, event.staff_user_ids]

    post pos_event_items_path(event), params: { compliance_catalog_item_id: ComplianceCatalogItem.find_by!(source_variant_id: '11').id, loaded_quantity: '12' }
    post pos_event_items_path(event), params: { compliance_catalog_item_id: flower.id, price: '25.00', loaded_quantity: '6' }
    assert_equal [4000, 2500], event.pos_event_items.reload.map(&:price_cents)

    post open_pos_event_path(event), params: { checklist: PosEvent::CHECKLIST.keys.index_with { '1' } }
    assert event.reload.open?
    get pos_event_path(event)
    assert_response :success
    assert_select 'a[href=?]', pos_event_register_path(event), 'Open event register'

    # Seller on the register.
    delete logout_path
    sign_in seller
    get ctrax_pos_path(location_id: @location.id)
    assert_select 'a.menu-item[href=?]', pos_event_register_path(event)
    get pos_event_register_path(event)
    assert_response :success
    assert_select '[data-controller="event-register"]'
    get pos_event_register_path(event, format: :json)
    assert_equal ['Hemp Extract 1000mg', 'Hemp Flower 3.5g'], response.parsed_body['items'].map { |i| i['name'] }

    sale = { client_sale_id: 'device-sale-0001', tender: 'cash', id_checked: true, cash_received: '50',
             lines: [{ event_item_id: event.pos_event_items.first.id, quantity: 1 }] }
    post pos_event_sales_path(event), params: sale, as: :json
    assert_response :success
    receipt = response.parsed_body
    assert_equal [4240, 760], receipt.values_at('total_cents', 'change_cents')
    post pos_event_sales_path(event), params: sale, as: :json
    assert_equal receipt['id'], response.parsed_body['id']
    assert_equal 1, PosEventSale.count

    post pos_event_sales_path(event), params: sale.merge(client_sale_id: 'device-sale-0002', tender: 'card_terminal', cash_received: nil,
      lines: [{ event_item_id: event.pos_event_items.last.id, quantity: 1 }]), as: :json
    assert_response :unprocessable_entity
    assert_equal true, response.parsed_body.dig('compliance', 'overridable')

    get receipt['receipt_url']
    assert_response :success
    assert_select '.coa-qr svg', 1
    assert_select '.coa-qr figcaption', 'Hemp Extract 1000mg'

    # Manager closes and reconciles.
    delete logout_path
    sign_in @owner
    post close_pos_event_path(event), params: { counted_cash: '142.40', terminal_card_total: '', counted: { event.pos_event_items.first.id.to_s => '11' } }
    assert event.reload.closed?
    get pos_event_path(event)
    assert_select 'h2', 'End-of-event reconciliation'
    get pos_event_path(event, format: :csv)
    assert_response :success
    assert_includes response.body, 'Hemp Extract 1000mg'
    assert_equal [0, 0], [event.cash_variance_cents, event.pos_event_items.first.counted_remaining - 11]
  end

  test 'a manager sets an override PIN only with their password' do
    sign_in @manager
    patch compliance_override_pin_path, params: { current_password: 'wrong', pin: '2468', pin_confirmation: '2468' }
    assert_not @manager.reload.valid_pos_override_pin?('2468')
    patch compliance_override_pin_path, params: { current_password: 'password123', pin: '2468', pin_confirmation: '2468' }
    assert @manager.reload.valid_pos_override_pin?('2468')
    assert_equal 'override_pin_set', ComplianceEvent.last.action
    delete logout_path
    sign_in cashier
    get edit_compliance_override_pin_path
    assert_response :redirect
  end
end
