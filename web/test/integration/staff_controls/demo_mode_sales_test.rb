# frozen_string_literal: true

require 'test_helper'

# Characterization: pins behaviour pending owner decision (docs/decisions/staff-controls-2026-11.md, item f).
# Any account that can use the register can start "Demo both screens" and complete a practice cash
# sale. It needs no open register and no checkout setup, and records no order, payment or stock change.
class StaffControlsDemoModeSalesTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @staff = User.create!(tenant: Current.tenant, email: 'demo-staff@example.test', password: 'password123', role: 'employee', name: 'Sam Staff')
    @location = Location.create!(source: 'ctrax', externalId: 'staff-controls/demo', name: 'Demo fixture')
    CtraxStockSnapshot.create!(location: @location, api_origin: 'https://fixture.api.cannatrax.net', store_id: '7', captured_at: Time.current,
      records_json: [{ 'id' => '3', 'name' => 'Tea', 'product_name' => 'Tea', 'price_cents' => 1005, 'tax_rate_mbp' => 600_000, 'quantity' => '4', 'manage_stock' => true, 'listed' => true }])
    sign_in @staff
  end
  teardown { Current.reset }

  test 'a staff account completes a demo cash sale that records no order, payment or stock change' do
    post pos_displays_path, params: { location_id: @location.id, demo: '1' }
    display = PosDisplaySession.sole
    assert display.demo?
    assert_redirected_to demo_pos_display_path(display)

    post customer_display_tip_path, params: { display_token: display.display_token, cart_revision: display.cart_revision, choice: 'none' }, as: :json
    assert_response :success
    post pos_checkouts_path, params: { display_id: display.id, tender: 'cash', cash_received: '20' }, as: :json
    assert_response :success

    assert_equal ['paid', true], response.parsed_body.values_at('status', 'demo')
    assert PosCheckout.sole.demo?
    assert_empty Core::Order.where(source: 'rupert_pos')
    assert_empty PosStockAllocation.all
    assert_empty Sales::PosSession.all
  end
end
