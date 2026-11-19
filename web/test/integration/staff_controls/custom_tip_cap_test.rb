# frozen_string_literal: true

require 'test_helper'

# Characterization: pins behaviour pending owner decision (docs/decisions/staff-controls-2026-11.md, item b).
# The tip is chosen on the customer screen, which the cashier can open on the same phone. A custom
# tip is accepted up to $999,999.99 whatever the cart is worth, and on a Card (A920) sale (recorded,
# never charged by Rupert) it is later shared out to whoever was clocked in: the cashier, if alone.
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

  test 'a custom tip of 999,999.99 is accepted on a 10.05 cart; one cent more is refused' do
    post customer_display_tip_path, params: tip_params('1000000'), as: :json
    assert_response :unprocessable_entity

    post customer_display_tip_path, params: tip_params('999999.99'), as: :json
    assert_response :success
    assert_equal 99_999_999, response.parsed_body['tip_cents']
  end

  test 'a 500.00 custom tip on a 10.05 Card (A920) sale is recorded and shared to the cashier who rang it' do
    ClockShift.create!(user: @cashier, employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name, employment_type: 'part_time',
      started_at: 1.hour.ago, request_token: SecureRandom.uuid, location_id: @location.id, source: 'pos')
    post customer_display_tip_path, params: tip_params('500'), as: :json
    assert_response :success

    post pos_checkouts_path, params: { display_id: @display.id, tender: 'card_a920', register_id: @register.id }, as: :json
    assert_response :success
    assert_equal ['paid', 50_000, 51_065], response.parsed_body.values_at('status', 'tip_cents', 'total_cents')
    checkout = PosCheckout.sole
    assert_equal [@cashier.id, 50_000], [checkout.user_id, checkout.order.tip_cents]
    assert_empty PosPaymentAttempt.all

    rows = Tips::Attribution.call(checkout.order)
    assert_equal [[@worker.id, 50_000]], rows.map { |row| [row.employee_id, row.amount_cents] }
  end

  private

  def tip_params(amount)
    { display_token: @display.display_token, cart_revision: @display.cart_revision, choice: 'custom', amount: amount }
  end
end
