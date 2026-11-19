# frozen_string_literal: true

require 'test_helper'
require 'base64'
require_relative '../support/dejavoo_spin_fixture'
require_relative '../support/ops_log_helper'

# A Dejavoo terminal profile number (TPN) identifies one payment terminal. It is saved
# encrypted with the terminal's key and must not be written to a request log when POS
# setup is saved, when an extra terminal is added, or when Dejavoo posts a closed batch.
# The structured production log records parameter names only; Rails' own log format
# (RUPERT_LOG_FORMAT=rails, and development) prints the filtered values, so both are checked.
class PosTerminalLogFilterTest < ActionDispatch::IntegrationTest
  include DejavooSpinFixture
  include OpsLogHelper

  EXTRA_TPN = 'SBXTPN0002'
  EXTRA_KEY = 'SbxAuth002'
  FEED_KEY = 'made-up-feed-key-for-tests-0002'
  FILTERED = '[FILTERED]'

  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @location = Location.create!(source: 'ctrax', externalId: 'dejavoo-log-filter/1', name: 'Log filter fixture')
    @setting = PosSetting.create!(location: @location, gateway_provider: 'dejavoo_spin', environment: 'sandbox', credentials_json: '{}',
      webhook_signing_key: FEED_KEY)
    post login_path, params: { email: @user.email, password: 'password' }
  end
  teardown { Current.reset }

  # Rails' default request lines ("Parameters: {...}"), as written when the log format is "rails".
  def capture_rails_log
    io = StringIO.new
    tap_logger = Logger.new(io, level: Logger::INFO)
    Rails.logger.broadcast_to(tap_logger)
    OpsLog.with_format('rails') { yield }
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(tap_logger)
  end

  test 'adding a terminal keeps its TPN and auth key out of the request log' do
    params = { terminal_name: 'Event terminal', register_name: 'event', terminal_tpn: EXTRA_TPN, terminal_auth_key: EXTRA_KEY }
    rails_log = capture_rails_log { post pos_setting_terminals_path(@location.id), params: params }
    assert_redirected_to pos_setting_path(@location.id)
    logged = request.filtered_parameters
    assert_equal [FILTERED, FILTERED], logged.values_at('terminal_tpn', 'terminal_auth_key')
    assert_equal ['Event terminal', 'event'], logged.values_at('terminal_name', 'register_name'), 'the labels still log'
    assert_includes rails_log, 'Parameters:'
    assert_includes rails_log, 'Event terminal'
    [EXTRA_TPN, EXTRA_KEY].each { |secret| assert_not_includes rails_log, secret }
    PosTerminal.sole.update!(retired_at: Time.current)
    capture_ops_log { post pos_setting_terminals_path(@location.id), params: params }
    [EXTRA_TPN, EXTRA_KEY].each { |secret| assert_not_includes ops_raw, secret }
    assert_equal 2, PosTerminal.count
    assert_equal({ 'tpn' => EXTRA_TPN, 'auth_key' => EXTRA_KEY }, PosTerminal.last.credentials, 'the terminal is saved as before')
  end

  test 'saving POS setup keeps the main TPN and auth key out of the request log' do
    rails_log = capture_rails_log do
      patch pos_setting_path(@location.id), params: { pos_setting: { lock_version: @setting.lock_version }, credentials: { tpn: TPN, auth_key: AUTH_KEY } }
    end
    assert_redirected_to pos_setting_path(@location.id)
    assert_equal FILTERED, request.filtered_parameters['credentials']
    assert_includes rails_log, 'Parameters:'
    [TPN, AUTH_KEY].each { |secret| assert_not_includes rails_log, secret }
    assert_equal({ 'tpn' => TPN, 'auth_key' => AUTH_KEY }, @setting.reload.credentials, 'the setup is saved as before')
  end

  test 'a closed-batch posting keeps the terminal number out of the request log and is still recorded' do
    settlement = { 'id' => 'b6a1f6c2-2222-4c7a-9d7e-000000000002', 'eventType' => 'Settlement', 'subEventType' => 'Batch Settlement', 'requestType' => 'N',
                   'version' => '1.0', 'createdDt' => '2026-11-03 23:00:00', 'tpn' => TPN, 'batchNumber' => '469', 'settlementDate' => '2026-11-03',
                   'settlementCount' => 12, 'settlementAmount' => 245.5, 'settlementTxnDetails' => [] }
    rails_log = capture_rails_log do
      post pos_webhook_path(@setting.id), params: settlement.to_json,
        headers: { 'Content-Type' => 'application/json', 'Authentication' => "Basic #{Base64.strict_encode64("rupert:#{FEED_KEY}")}" }
    end
    assert_response :ok
    assert_equal FILTERED, request.filtered_parameters['tpn']
    assert_equal '469', request.filtered_parameters['batchNumber'], 'the batch number still logs'
    assert_includes rails_log, 'Parameters:'
    assert_not_includes rails_log, TPN
    assert_equal [TPN, '469'], DejavooFeedEvent.sole.values_at(:tpn, :batch_number), 'the batch is recorded as before'
  end

  test 'only the terminal number is hidden; batch and reconciliation names that contain "tpn" still log' do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    hidden = filter.filter('tpn' => TPN, 'Tpn' => TPN, 'TPN' => TPN, 'terminal_tpn' => TPN)
    assert_equal [FILTERED], hidden.values.uniq
    kept = filter.filter('tpnBatchNumber' => '469', 'batch_number' => '469', 'terminal_name' => 'Event terminal', 'register_name' => 'event')
    assert_equal ['469', '469', 'Event terminal', 'event'], kept.values
  end
end
