# frozen_string_literal: true

require 'test_helper'

# Owner decision (docs/decisions/staff-controls-2026-11.md, item b): a custom tip is at most
# $500.00, whatever the sale. The percentage buttons and "No tip" are unchanged.
class StaffControlsCustomTipCapTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    Finance::ChartOfAccounts.seed!
    @cashier = User.create!(tenant: Current.tenant, email: 'tip-cashier@example.test', password: 'password123', role: 'cashier', name: 'Casey Cashier')
    @worker = People::Employee.create!(user: @cashier, first_name: 'Casey', last_name: 'Cashier', employment_type: 'part_time')
    @location = Location.create!(source: 'ctrax', externalId: 'staff-controls/tip', name: 'Tip fixture')
    @snapshot = CtraxStockSnapshot.create!(location: @location, api_origin: 'https://fixture.api.cannatrax.net', store_id: '7', captured_at: Time.current,
      records_json: [{ 'id' => '3', 'name' => 'Tea', 'product_name' => 'Tea', 'price_cents' => 1005, 'tax_rate_mbp' => 600_000, 'quantity' => '4', 'manage_stock' => true, 'listed' => true }])
    PosConnection.create!(provider: 'ctrax', vendor_approved: true, credentials_json: { api_url: @snapshot.api_origin, api_username: 'fixture', api_password: 'private-fixture' }.to_json)
    PosSetting.create!(location: @location, cash_enabled: true)
    @register = Sales::PosSession.create!(location: @location, user: users(:regular_user), name: 'Front', opened_at: Time.current)
    Ctrax::StockSync.stubs(:call).returns(stores: 1, variants: 1)
    sign_in @cashier
    @display = PosDisplaySession.create!(user: @cashier, location: @location)
    post quote_ctrax_pos_path(@location.id, display_id: @display.id), params: { items: [{ variant_id: '3', quantity: 1 }] }, as: :json
    assert_response :success
    @display.reload
  end
  teardown { Current.reset }

  test 'a custom tip above 500.00 is refused with the limit; 500.00 is accepted' do
    post customer_display_tip_path, params: tip_params('999999.99'), as: :json
    assert_response :unprocessable_entity
    assert_equal 'The largest custom tip is $500.00. Enter a smaller amount, or ask the cashier.', response.parsed_body['error']
    post customer_display_tip_path, params: tip_params('500.01'), as: :json
    assert_response :unprocessable_entity
    assert_nil @display.reload.chosen_tip_cents

    post customer_display_tip_path, params: tip_params('500'), as: :json
    assert_response :success
    assert_equal 50_000, response.parsed_body['tip_cents']
  end

  test 'a generous tip on a small sale is allowed: 300.00 on a 10.05 cart' do
    post customer_display_tip_path, params: tip_params('300'), as: :json
    assert_response :success
    assert_equal 30_000, response.parsed_body['tip_cents']
  end

  test 'the limit is the same on a larger cart' do
    post quote_ctrax_pos_path(@location.id, display_id: @display.id), params: { items: [{ variant_id: '3', quantity: 4 }] }, as: :json
    assert_response :success
    @display.reload
    assert_equal 4020, @display.subtotal_cents
    assert_equal 50_000, @display.max_custom_tip_cents

    post customer_display_tip_path, params: tip_params('500.01'), as: :json
    assert_response :unprocessable_entity
    post customer_display_tip_path, params: tip_params('500.00'), as: :json
    assert_response :success
  end

  test 'a 999,999.99 custom tip cannot be put on a Card (A920) sale' do
    post customer_display_tip_path, params: tip_params('999999.99'), as: :json
    assert_response :unprocessable_entity

    post pos_checkouts_path, params: { display_id: @display.id, tender: 'card_a920', register_id: @register.id }, as: :json
    assert_response :unprocessable_entity
    assert_empty PosCheckout.all
  end

  test 'percentage tips and no tip are unchanged' do
    post customer_display_tip_path, params: tip_params(nil).merge(choice: '20'), as: :json
    assert_response :success
    assert_equal 201, response.parsed_body['tip_cents']
  end

  private

  def tip_params(amount)
    { display_token: @display.display_token, cart_revision: @display.cart_revision, choice: 'custom', amount: amount }
  end
end
