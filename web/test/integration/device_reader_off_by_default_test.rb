# frozen_string_literal: true

require 'test_helper'
require_relative '../support/device_reader_fixture'

# Phone card reader payments are inert unless switched on three ways: a real
# provider exists for the environment (none does in production), the
# deployment switch is on, and the workspace's own flag is on. With any of
# them off, the routes refuse, the provider cannot be saved or chosen, and no
# other payment path behaves differently.
class DeviceReaderOffByDefaultTest < ActionDispatch::IntegrationTest
  include DeviceReaderFixture
  include ActiveJob::TestHelper

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = users(:regular_user)
    @plain = Location.create!(source: 'ctrax', externalId: 'device-off/1', name: 'Device off store')
  end
  teardown do
    Rails.application.config.x.device_reader_enabled = true
    Current.reset
  end

  def in_workspace = Current.set(tenant: @tenant) { yield }

  def all_routes(token = 'f' * 64)
    yield post(native_reader_attempt_path(@checkout.id), as: :json)
    yield get(native_reader_attempt_path(@checkout.id))
    yield post(start_native_reader_attempt_path, params: { token: token, device_id: DEVICE }, as: :json)
    yield post(result_native_reader_attempt_path, params: { token: token, device_id: DEVICE, result: { status: 'approved', amount_cents: 1166 } }, as: :json)
    yield post(status_native_reader_attempt_path, params: { token: token, device_id: DEVICE }, as: :json)
    yield post(cancel_native_reader_attempt_path, params: { token: token, device_id: DEVICE }, as: :json)
  end

  test 'a workspace has the flag off until someone sets it, and no settings screen offers it' do
    assert_not FeatureFlag.enabled?(:device_reader)
    assert_not Pos::DeviceReader.enabled?
    assert Pos::DeviceReader.available?, 'the test and development deployment switch is on'
    sign_in(@admin)
    get settings_path
    assert_response :success
    assert_not_includes response.body, 'device_reader'
    assert_not_includes response.body, 'Phone card reader'
    get pos_setting_path(@plain.id)
    assert_response :success
    assert_not_includes response.body, 'device_reader'
    assert_not_includes response.body, 'Phone card reader'
    get processor_catalogs_path
    assert_response :success
    assert_not_includes response.body, 'Phone card reader'
  end

  test 'with the workspace flag off every route answers 404 and changes nothing' do
    prepare_device_reader_fixture(user: @admin, name: 'flag-off')
    token = Pos::DeviceReaderPayment.token_for(Pos::DeviceReaderPayment.open!(@checkout))
    FeatureFlag.set(:device_reader, false)
    before = attempt.attributes
    sign_in(@admin)
    all_routes(token) { assert_response :not_found }
    assert_no_enqueued_jobs
    in_workspace do
      assert_equal before, attempt.attributes
      assert_raises(Pos::Error) { Pos::DeviceReaderPayment.open!(device_reader_checkout(display: PosDisplaySession.create!(user: @admin, location: @location))) }
      assert_raises(Pos::Error) { Pos::DeviceReaderPayment.start!(attempt, device_id: DEVICE) }
    end
  end

  test 'with the deployment switch off the routes do not exist' do
    prepare_device_reader_fixture(user: @admin, name: 'switch-off')
    sign_in(@admin)
    Rails.application.config.x.device_reader_enabled = false
    all_routes { assert_response :not_found }
    in_workspace do
      assert_not Pos::DeviceReader.enabled?
      assert_equal 0, @checkout.pos_payment_attempts.count
      assert_match(/not available/, assert_raises(Pos::Error) { Pos::DeviceReader.gateway(@setting) }.message)
    end
  end

  test 'production has no provider at all, whatever the switches say' do
    prepare_device_reader_fixture(user: @admin, name: 'production')
    sign_in(@admin)
    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new('production'))
    assert_nil Pos::DeviceReader.gateway_class
    assert_not Pos::DeviceReader.available?
    assert_not in_workspace { Pos::DeviceReader.enabled? }
    all_routes { assert_response :not_found }
    in_workspace do
      assert_raises(Pos::Error) { Pos::DeviceReader.gateway(@setting) }
      assert_match(/never runs in production/, assert_raises(Pos::Error) { Pos::DeviceReader::FakeGateway.new(@setting) }.message)
      assert_raises(Pos::Error) { Pos::DeviceReaderPayment.open!(@checkout) }
      assert_raises(Pos::Error) { Pos::DeviceReaderPayment.reconcile!(PosPaymentAttempt.new(pos_checkout: @checkout, invoice: 'RRx', status: 'unknown')) }
      assert_not @setting.valid?
      assert_equal 0, @checkout.pos_payment_attempts.count
    end
  end

  test 'the deployment switch defaults to off in production and on elsewhere' do
    source = Rails.root.join('config/initializers/device_reader.rb').read
    assert_includes source, "ENV.fetch('RUPERT_DEVICE_READER_ENABLED') { Rails.env.production? ? '0' : '1' } == '1'"
    assert_nil ENV['RUPERT_DEVICE_READER_ENABLED'], 'the test run does not force the switch'
  end

  test 'the provider cannot be saved or chosen while the flag is off' do
    setting = PosSetting.new(location: @plain, gateway_provider: 'device_reader', environment: 'sandbox', credentials_json: device_reader_credentials)
    assert_not setting.valid?
    assert_match(/not enabled/, setting.errors.full_messages.to_sentence)
    sign_in(@admin)
    patch pos_setting_path(@plain.id), params: { pos_setting: { gateway_provider: 'device_reader', environment: 'sandbox' },
                                                 credentials: { merchant_id: 'FIXTURE-MERCHANT', reader_profile_id: 'FIXTURE-PROFILE' } }
    assert_response :unprocessable_entity
    assert_empty in_workspace { PosSetting.where(location: @plain).to_a }
  end

  test 'a store saved while the flag was on stops taking phone payments when it is turned off' do
    prepare_device_reader_fixture(user: @admin, name: 'turned-off')
    FeatureFlag.set(:device_reader, false)
    assert_not @setting.reload.valid?
    display = PosDisplaySession.create!(user: @admin, location: @location)
    display.stubs(:active?).returns(true)
    display.stubs(:confirmed?).returns(true)
    assert_match(/not enabled for this store/, assert_raises(Pos::Error) { Pos::Checkout.prepare!(display: display, tender: 'card', register_id: @register.id) }.message)
  end

  test 'payments already taken can still be looked up and refunded after the workspace flag is turned off' do
    prepare_device_reader_fixture(user: @admin, name: 'wind-down')
    opened = Pos::DeviceReaderPayment.open!(@checkout)
    Pos::DeviceReaderPayment.start!(opened, device_id: DEVICE)
    tap
    FeatureFlag.set(:device_reader, false)
    Pos::CardPayment.reconcile!(opened)
    assert @checkout.reload.paid?
    assert_equal 'succeeded', Pos::CardReversal.call(checkout: @checkout, amount_cents: 1166, reason: 'Customer return', user: @admin).status
  end

  test 'with the flag on, an owner can choose the provider, and production still needs sign-off' do
    FeatureFlag.set(:device_reader, true)
    sign_in(@admin)
    get pos_setting_path(@plain.id)
    assert_select 'select[name="pos_setting[gateway_provider]"] option[value="device_reader"]', text: 'Phone card reader'
    patch pos_setting_path(@plain.id), params: { pos_setting: { gateway_provider: 'device_reader', environment: 'sandbox' },
                                                 credentials: { merchant_id: 'FIXTURE-MERCHANT', reader_profile_id: 'FIXTURE-PROFILE', tpn: 'IGNORED12345' } }
    assert_redirected_to pos_setting_path(@plain.id)
    setting = in_workspace { PosSetting.find_by!(location: @plain) }
    assert_equal({ 'merchant_id' => 'FIXTURE-MERCHANT', 'reader_profile_id' => 'FIXTURE-PROFILE' }, setting.credentials)
    raw = ActiveRecord::Base.connection.select_value("SELECT credentials_json FROM pos_settings WHERE id = #{setting.id}")
    assert_not_includes raw, 'FIXTURE-MERCHANT', 'the identifiers are encrypted at rest'
    get pos_setting_path(@plain.id)
    assert_select 'input[name="credentials[merchant_id]"][type=password]'
    assert_not_includes response.body, 'FIXTURE-MERCHANT'
    post verify_pos_setting_path(@plain.id)
    assert_match(/identifiers checked/, flash[:notice])
    in_workspace do
      setting.reload
      assert setting.verified_at
      setting.update!(card_enabled: true)
      assert_not setting.update(environment: 'production')
      assert_match(/Phone card reader production needs owner sign-off/, setting.errors.full_messages.to_sentence)
      setting.reload.update!(environment: 'production', production_approved_at: Time.current, production_approved_by: @admin,
        production_approval_note: 'Fixture approval recorded for the test')
      assert_not setting.card_enabled, 'changing the account turns card charges off until it is checked again'
      setting.update!(credentials_json: { merchant_id: 'FIXTURE-OTHER', reader_profile_id: 'FIXTURE-PROFILE' }.to_json, environment: 'sandbox')
      assert_nil setting.production_approved_at, 'new merchant identifiers need a new sign-off'
    end
  end
end
