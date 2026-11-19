# frozen_string_literal: true

require 'test_helper'
require_relative '../support/dejavoo_spin_fixture'

# A register with its own Dejavoo terminal sends its sales, refunds and batch
# close to that terminal's TPN; other registers keep the main TPN.
class DejavooExtraTerminalsTest < ActionDispatch::IntegrationTest
  include DejavooSpinFixture
  include ActiveJob::TestHelper

  EVENT_TPN = 'SBXTPN0002'
  EVENT_KEY = 'SbxAuth002'

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
    @register = Sales::PosSession.create!(location: @location, user: @user, name: 'Event', opened_at: Time.current)
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

  def add_event_terminal(check: true)
    @spin_extra_terminals = { EVENT_TPN => EVENT_KEY }
    post pos_setting_terminals_path(@location.id), params: { terminal_name: 'Event terminal', register_name: 'event', terminal_tpn: EVENT_TPN, terminal_auth_key: EVENT_KEY }
    terminal = PosTerminal.sole
    post check_pos_setting_terminal_path(@location.id, terminal.id) if check
    terminal.reload
  end

  def checkout!
    post pos_checkouts_path, params: { display_id: @display.id, tender: 'card', register_id: @register.id }, as: :json
    assert_response :success
    PosCheckout.find(response.parsed_body['id'])
  end

  test 'a checked terminal takes its register’s sales, refunds and batch' do
    terminal = add_event_terminal
    assert terminal.verified_at
    assert_equal EVENT_TPN, @spin_requests.last.last['Tpn'], 'the check used the new terminal'
    checkout = checkout!
    assert_equal terminal.id, checkout.pos_terminal_id
    perform_enqueued_jobs(only: PosTerminalSaleJob)
    assert checkout.reload.paid?
    sale = @spin_requests.find { |path, _| path == 'v2/Payment/Sale' }.last
    assert_equal EVENT_TPN, sale['Tpn']
    reversal = Pos::CardReversal.call(checkout: checkout, amount_cents: checkout.total_cents, reason: 'Customer return', user: @user)
    assert_equal 'succeeded', reversal.status
    assert_equal EVENT_TPN, @spin_requests.last.last['Tpn']
    results = Pos::DejavooBatchClose.call(@setting)
    assert_equal ['Main terminal', 'Event terminal'], results.map(&:terminal_name)
    assert_equal [TPN, EVENT_TPN], @spin_requests.select { |path, _| path == 'v2/Payment/Settle' }.map { |_, body| body['Tpn'] }
  end

  test 'an unchecked or retired terminal is never used and the register falls back to the main TPN' do
    terminal = add_event_terminal(check: false)
    assert_nil checkout!.pos_terminal_id
    post check_pos_setting_terminal_path(@location.id, terminal.id)
    post retire_pos_setting_terminal_path(@location.id, terminal.id)
    assert terminal.reload.retired_at
    assert_nil PosTerminal.for_register(@location, @register)
  end

  test 'a register gets one terminal, the main TPN cannot be reused and keys never show' do
    add_event_terminal
    post pos_setting_terminals_path(@location.id), params: { terminal_name: 'Second', register_name: 'EVENT', terminal_tpn: 'SBXTPN0003', terminal_auth_key: 'SbxAuth003' }
    assert_match(/already has a terminal/, flash[:alert])
    post pos_setting_terminals_path(@location.id), params: { terminal_name: 'Copy', register_name: 'Back', terminal_tpn: TPN, terminal_auth_key: AUTH_KEY }
    assert_match(/main TPN/, flash[:alert])
    get pos_setting_path(@location.id)
    assert_includes response.body, 'Event terminal'
    assert_includes response.body, '…0002'
    assert_not_includes response.body, EVENT_KEY
    assert_equal 1, PosTerminal.count
  end
end
