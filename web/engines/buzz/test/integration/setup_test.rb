# frozen_string_literal: true

require_relative '../test_helper'

# The Setup page: relay and channel, the Rupert identity, the relay check.
class BuzzSetupTest < ActionDispatch::IntegrationTest
  include BuzzChatHelper

  setup do
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
    @tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    @admin.update_permission_overrides!((User::ROLE_PERMISSIONS.fetch('admin') + ['buzz.read', 'settings.read', 'settings.write']).uniq)
  end

  teardown { stop_buzz_relay }

  def sign_in(user, password = 'password')
    post login_path, params: { email: user.email, password: password }
  end

  def setting_row(key) = Setting.find_by(key: key, tenant_id: @tenant.id)

  test 'only people who may change settings can open or change it' do
    reader = User.create!(tenant: @tenant, email: 'buzz-reader@example.com', role: 'manager', password: 'password123', name: 'Reader')
    reader.update_permission_overrides!(['dashboard.read', 'buzz.read'])
    sign_in(reader, 'password123')
    get buzz_setup_path
    assert_redirected_to root_path
    patch buzz_setup_path, params: { relay_url: 'wss://evil.example.com' }
    assert_nil setting_row('BUZZ_RELAY_URL')
    get buzz_chat_path
    assert_select "a[href='#{buzz_setup_path}']", 0
  end

  test 'the relay and channel are saved encrypted and checked' do
    sign_in(@admin)
    get buzz_setup_path
    assert_response :success
    assert_select 'h1', 'Buzz'
    assert_select "nav.tabs a[href='#{buzz_setup_path}'][aria-current=page]"

    patch buzz_setup_path, params: { relay_url: 'wss://buzz.example.com', channel: BuzzChatHelper::CHANNEL.upcase }
    assert_redirected_to buzz_setup_path
    assert_equal 'wss://buzz.example.com', setting_row('BUZZ_RELAY_URL').value
    assert_equal BuzzChatHelper::CHANNEL, setting_row('BUZZ_CHANNEL').value
    raw = Setting.connection.select_value(Setting.where(key: 'BUZZ_RELAY_URL', tenant_id: @tenant.id).select(:value).to_sql)
    refute_includes raw, 'buzz.example.com', 'stored encrypted'

    patch buzz_setup_path, params: { relay_url: 'javascript:alert(1)', channel: '' }
    assert_equal 'wss://buzz.example.com', setting_row('BUZZ_RELAY_URL').value
    assert_match(/ws:\/\/ or wss:\/\//, flash[:alert])
    patch buzz_setup_path, params: { relay_url: 'wss://buzz.example.com', channel: 'general' }
    assert_match(/UUID/, flash[:alert])
  end

  test 'creating the identity stores a key that is never shown, and the profile goes to the relay' do
    start_buzz_relay
    Buzz::Settings.set(Buzz::Settings::PRIVATE_KEY, nil)
    sign_in(@admin)
    post buzz_setup_keypair_path
    assert_redirected_to buzz_setup_path
    Current.tenant = @tenant
    key = Buzz::Identity.private_key_hex
    npub = Buzz::Identity.npub
    assert_match(/\A\h{64}\z/, key)
    follow_redirect!
    assert_includes response.body, npub
    refute_includes response.body, key
    Current.tenant = @tenant
    pubkey = Buzz::Identity.public_key_hex

    post buzz_setup_profile_path
    assert_match(/Profile published/, flash[:notice])
    profile = @relay.published.find { |event| event['kind'].zero? }
    assert_equal pubkey, profile['pubkey']
    assert_equal 'Rupert', JSON.parse(profile['content'])['name']

    post buzz_setup_check_path
    assert_match(/knows Rupert/, flash[:notice])
  end

  test 'a check against a relay that is down says so plainly' do
    start_buzz_relay
    key = Buzz::Identity.private_key_hex
    @relay.stop
    sign_in(@admin)
    post buzz_setup_check_path
    assert_match(/could not use the relay/, flash[:alert])
    refute_includes flash[:alert].to_s, key
  end
end
