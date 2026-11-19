# frozen_string_literal: true

require 'test_helper'

# The cashier screen on a phone (docs/ui-standards.md §5, POS): what the server renders so the
# stylesheet and the controllers can keep the strip short, the keyboard down and the hand-over
# for the tip one tap away. Layout itself is checked in the iPhone simulator
# (ios/RupertApp/UITests/EmployeeShiftUITests.swift).
class PosPhoneRegisterTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @location = Location.create!(source: 'ctrax', externalId: 'fixture/7', name: 'Phone fixture')
    CtraxStockSnapshot.create!(location: @location, api_origin: 'https://fixture.api.cannatrax.net', store_id: '7', captured_at: Time.current,
      records_json: [{ 'id' => '3', 'name' => 'Tea', 'product_name' => 'Tea', 'price_cents' => 1005, 'tax_rate_mbp' => 600_000, 'quantity' => '4', 'manage_stock' => true, 'listed' => true }])
    PosSetting.create!(location: @location, cash_enabled: true)
    @register = Sales::PosSession.create!(location: @location, user: @user, name: 'Front', opened_at: Time.current)
    @display = PosDisplaySession.create!(user: @user, location: @location)
    post login_path, params: { email: @user.email, password: 'password' }
  end
  teardown { Current.reset }

  test 'search is not focused by the page, so a phone keyboard does not open over the products' do
    get ctrax_pos_path(location_id: @location.id)
    assert_response :success
    assert_select '#pos_q'
    assert_select '#pos_q[autofocus]', false
  end

  test 'controls the phone strip drops are in More, and the wide ones are marked' do
    get ctrax_pos_path(location_id: @location.id, display_id: @display.id)
    assert_select '.pos-topbar-status a.pos-wide-only', 'Open customer screen'
    assert_select '.pos-topbar-status button.pos-wide-only', 'Close'
    assert_select '.pos-topbar-end a.pos-exit.pos-wide-only', 'Exit POS'
    assert_select '.menu-panel a.menu-item.pos-phone-only[href=?]', customer_display_path(display_token: @display.display_token), text: 'Open customer screen'
    assert_select '.menu-panel button.menu-item.pos-phone-only', 'Close customer screen'
    assert_select '.menu-panel a.menu-item.pos-phone-only', 'Exit POS'
    assert_select '.pos-topbar-status .pill-fern.pos-pill-quiet', 'Stock read current'
    assert_select 'body.native-app', false
  end

  test 'POS-only staff get My time and Sign out in More on a phone' do
    @user.update!(role: 'employee')
    get ctrax_pos_path(location_id: @location.id, display_id: @display.id)
    assert_response :success
    assert_select '.menu-panel a.menu-item.pos-phone-only', 'My time'
    assert_select '.menu-panel button.menu-item.pos-phone-only', 'Sign out'
    assert_select '.pos-topbar-end > a.pos-wide-only', 'My time'
  end

  test 'a stale stock read keeps its pill on a phone' do
    CtraxStockSnapshot.where(location: @location).update_all(captured_at: 2.hours.ago)
    get ctrax_pos_path(location_id: @location.id)
    assert_select '.pos-topbar-status .pill-clay', 'Stock read stale'
    assert_select '.pos-pill-quiet', false
  end

  test 'a paired cart offers the hand-over to the customer screen and the cart bar carries a total' do
    get ctrax_pos_path(location_id: @location.id, display_id: @display.id)
    assert_select 'a.pos-handover[data-pos-display-target="handover"][href=?]', customer_display_path(display_token: @display.display_token, handover: 1), text: 'Hand to customer for tip'
    assert_select 'a.pos-cart-jump [data-pos-cart-target="jumpTotal"]'
    assert_select '.pos-app[data-pos-cart-paid-value="false"]'
    get ctrax_pos_path(location_id: @location.id)
    assert_select 'a.pos-handover', false
  end

  test 'the customer screen opened by hand-over knows to ask for the phone back' do
    get customer_display_path(display_token: @display.display_token, handover: 1)
    assert_select 'main[data-customer-tip-handover-value="true"]'
    get customer_display_path(display_token: @display.display_token)
    assert_select 'main[data-customer-tip-handover-value="false"]'
  end

  test 'a register reloaded on a paid cart is told so, and starts the next sale' do
    post quote_ctrax_pos_path(@location.id, display_id: @display.id), params: { items: [{ variant_id: '3', quantity: 1 }], tip_type: 'none' }, as: :json
    assert_response :success
    @display.reload.choose_tip!(revision: @display.cart_revision, choice: 'none')
    PosConnection.create!(provider: 'ctrax', vendor_approved: true, credentials_json: { api_url: 'https://fixture.api.cannatrax.net', api_username: 'fixture', api_password: 'private-fixture' }.to_json)
    Ctrax::StockSync.stubs(:call).returns(stores: 1, variants: 1)
    post pos_checkouts_path, params: { display_id: @display.id, tender: 'cash', register_id: @register.id, cash_received: '20' }, as: :json
    assert_response :success
    assert_equal 'paid', response.parsed_body['status']
    get ctrax_pos_path(location_id: @location.id, display_id: @display.id)
    assert_select '.pos-app[data-pos-cart-paid-value="true"]'
    assert_no_difference -> { PosCheckout.count } do
      post clear_pos_display_path(@display)
    end
    assert_response :no_content
    get ctrax_pos_path(location_id: @location.id, display_id: @display.id)
    assert_select '.pos-app[data-pos-cart-paid-value="false"]'
  end

  test 'the native app gets its class on the POS page, for the strip without the mark' do
    get ctrax_pos_path(location_id: @location.id), headers: { 'User-Agent' => 'Rupert/1.0 (iPhone) Hotwire Native iOS; Turbo Native iOS' }
    assert_select 'body.pos-body.native-app'
  end
end
