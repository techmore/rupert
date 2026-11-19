# frozen_string_literal: true

require 'test_helper'
require_relative '../support/dejavoo_spin_fixture'

class DejavooPosSettingsTest < ActionDispatch::IntegrationTest
  include DejavooSpinFixture

  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @location = Location.create!(source: 'ctrax', externalId: 'dejavoo-settings/1', name: 'Dejavoo settings fixture')
    @setting = PosSetting.create!(location: @location, gateway_provider: 'authorize_net', credentials_json: '{}')
    prepare_dejavoo_fixture
    post login_path, params: { email: @user.email, password: 'password' }
  end
  teardown { Current.reset }

  test 'an owner saves a sandbox TPN and auth key, checks the terminal and the keys stay encrypted' do
    patch pos_setting_path(@location.id), params: { pos_setting: { gateway_provider: 'dejavoo_spin', environment: 'sandbox', lock_version: @setting.reload.lock_version } }
    assert_redirected_to pos_setting_path(@location.id)
    get pos_setting_path(@location.id)
    assert_select 'input[name="credentials[tpn]"]'
    assert_select 'input[name="credentials[auth_key]"]'
    assert_select 'input[name="credentials[api_login_id]"]', count: 0
    patch pos_setting_path(@location.id), params: { pos_setting: { lock_version: @setting.reload.lock_version }, credentials: { tpn: TPN, auth_key: AUTH_KEY, api_login_id: 'ignored' } }
    assert_redirected_to pos_setting_path(@location.id)
    assert_equal({ 'tpn' => TPN, 'auth_key' => AUTH_KEY }, @setting.reload.credentials)
    assert_not_includes @setting.attributes_before_type_cast['credentials_json'], AUTH_KEY
    post verify_pos_setting_path(@location.id)
    assert_redirected_to pos_setting_path(@location.id)
    assert_match(/Dejavoo sandbox terminal reached/, flash[:notice])
    assert @setting.reload.verified_at
    assert_nil @setting.public_client_key
    assert_equal ['v2/Payment/Status'], spin_paths, 'checking setup never runs a card'
    get pos_setting_path(@location.id)
    assert_not_includes response.body, AUTH_KEY
  end

  test 'Dejavoo production cannot be saved' do
    patch pos_setting_path(@location.id), params: { pos_setting: { gateway_provider: 'dejavoo_spin', environment: 'production', lock_version: @setting.reload.lock_version } }
    assert_response :unprocessable_entity
    assert_equal 'authorize_net', @setting.reload.gateway_provider
  end

  test 'an offline terminal fails the check' do
    @setting.update!(gateway_provider: 'dejavoo_spin', credentials_json: dejavoo_credentials)
    stub_request(:post, "#{HOST}/v2/Payment/Status").to_return(spin_json('2001', nil))
    post verify_pos_setting_path(@location.id)
    assert_match(/not connected/, flash[:alert])
    assert_nil @setting.reload.verified_at
  end
end
