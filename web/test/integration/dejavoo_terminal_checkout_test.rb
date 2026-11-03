# frozen_string_literal: true

require 'test_helper'
require_relative '../support/dejavoo_spin_fixture'

# The register sends a card sale to the Dejavoo terminal, the terminal wait runs
# in a job, and the cashier can cancel or re-send. Sandbox only.
class DejavooTerminalCheckoutTest < ActionDispatch::IntegrationTest
  include DejavooSpinFixture
  include ActiveJob::TestHelper

  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @location = Location.create!(source: 'ctrax', externalId: 'dejavoo-register/7', name: 'Dejavoo register fixture')
    @snapshot = CtraxStockSnapshot.create!(location: @location, api_origin: 'https://fixture.api.cannatrax.net', store_id: '7', captured_at: Time.current,
      records_json: [{ 'id' => '3', 'name' => 'Tea', 'product_name' => 'Tea', 'price_cents' => 1005, 'tax_rate_mbp' => 600_000, 'quantity' => '4', 'manage_stock' => true, 'listed' => true }])
    PosConnection.create!(provider: 'ctrax', vendor_approved: true, credentials_json: { api_url: @snapshot.api_origin, api_username: 'fixture', api_password: 'private-fixture' }.to_json)
    @setting = PosSetting.create!(location: @location, gateway_provider: 'dejavoo_spin', environment: 'sandbox', credentials_json: dejavoo_credentials)
    @setting.update!(verified_at: Time.current)
    @setting.update!(card_enabled: true)
    @register = Sales::PosSession.create!(location: @location, user: @user, name: 'Front', opened_at: Time.current)
    @display = PosDisplaySession.create!(user: @user, location: @location)
    ProcessorCatalog.create!(processor: 'dejavoo_spin')
    prepare_dejavoo_fixture
    @spin_total = '10.65'
    @spin_tip = '0'
    Pos::Checkout.stubs(:assert_eligible!).returns(true)
    Ctrax::StockSync.stubs(:call).returns(stores: 1, variants: 1)
    post login_path, params: { email: @user.email, password: 'password' }
    post quote_ctrax_pos_path(@location.id, display_id: @display.id), params: { items: [{ variant_id: '3', quantity: 1 }] }, as: :json
    assert_response :success
    @display.reload
    post customer_display_tip_path, params: { display_token: @display.display_token, cart_revision: @display.cart_revision, choice: 'none' }, as: :json
    assert_response :success
  end
  teardown { Current.reset }

  test 'a card sale goes to the terminal without waiting, then the job records the payment' do
    post pos_checkouts_path, params: { display_id: @display.id, tender: 'card', register_id: @register.id }, as: :json
    assert_response :success
    body = response.parsed_body
    assert body['terminal']
    assert_equal 'processing', body['status']
    assert_equal 0, spin_sales, 'the web request never waits on the terminal'
    perform_enqueued_jobs(only: PosTerminalSaleJob)
    assert_equal 1, spin_sales
    assert PosCheckout.find(body['id']).paid?
  end

  test 'cashier can cancel a waiting sale and send it again after the terminal reports the cancel' do
    @spin_sale_mode = :canceled
    post pos_checkouts_path, params: { display_id: @display.id, tender: 'card', register_id: @register.id }, as: :json
    id = response.parsed_body['id']
    post terminal_cancel_pos_checkout_path(id), as: :json
    assert_response :success
    assert_includes spin_paths, 'v2/Payment/AbortTransaction'
    perform_enqueued_jobs(only: PosTerminalSaleJob)
    assert_equal 'declined', PosCheckout.find(id).status
    @spin_sale_mode = :approved
    post terminal_pos_checkout_path(id), as: :json
    assert_response :success
    assert_equal 'processing', response.parsed_body['status']
    perform_enqueued_jobs(only: PosTerminalSaleJob)
    assert PosCheckout.find(id).paid?
    assert_equal 2, spin_sales
  end

  test 'a second send while a sale is waiting sends nothing new' do
    post pos_checkouts_path, params: { display_id: @display.id, tender: 'card', register_id: @register.id }, as: :json
    id = response.parsed_body['id']
    post terminal_pos_checkout_path(id), as: :json
    assert_response :success
    assert_equal 1, enqueued_jobs.count { |job| job['job_class'] == 'PosTerminalSaleJob' }
  end
end
