# frozen_string_literal: true

require 'test_helper'

# The iPhone app's APNs token and the installed web app's Web Push subscription are tied to the
# signed-in person's session; they are addresses, so sign-out and account deletion drop them.
class PushDevicesTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @worker_user = User.create!(tenant: @tenant, name: 'Push Worker', email: 'push-worker@example.com', role: 'employee', password: 'password123')
    @worker = People::Employee.create!(user: @worker_user, first_name: 'Push', last_name: 'Worker', employment_type: 'part_time')
    @worker.set_pin!('2580')
  end

  teardown { Current.reset }

  test 'the app registers its token for the signed-in person and forgets it on sign-out' do
    post native_push_devices_path, params: { platform: 'ios', token: 'abc123' }, as: :json
    assert_redirected_to login_path
    assert_equal 0, PushDevice.count, 'needs a session'
    sign_in @worker_user
    post native_push_devices_path, params: { platform: 'ios', token: 'abc123', environment: 'sandbox', app_version: '1.1.0 (20)' }, as: :json
    assert_response :created
    body = response.parsed_body
    device = PushDevice.find(body['id'])
    assert_equal @worker_user.id, device.user_id
    assert_equal 'sandbox', device.environment
    assert_equal false, body['push_configured']
    post native_push_devices_path, params: { platform: 'ios', token: 'abc123' }, as: :json
    assert_equal 1, PushDevice.where(user_id: @worker_user.id).count, 'registering again updates in place'
    delete native_push_device_path(body['token_digest'])
    assert_response :no_content
    assert_equal 'signed out', device.reload.failure_reason
    post native_push_devices_path, params: { platform: 'android', token: 'x' }, as: :json
    assert_response :unprocessable_entity
  end

  test 'the web app subscribes with an endpoint and keys' do
    sign_in @worker_user
    post employee_push_subscriptions_path, params: { subscription: { endpoint: 'https://push.example/sub/1', keys: { p256dh: 'p', auth: 'a' } } }, as: :json
    assert_response :created
    device = PushDevice.find(response.parsed_body['id'])
    assert_equal 'web', device.platform
    assert_equal({ 'p256dh' => 'p', 'auth' => 'a' }, device.keys)
    post employee_push_subscriptions_path, params: { subscription: { endpoint: 'http://insecure.example', keys: { p256dh: 'p', auth: 'a' } } }, as: :json
    assert_response :unprocessable_entity
    post unsubscribe_employee_push_path(device)
    assert_redirected_to employee_notification_settings_path
    assert device.reload.disabled_at.present?
  end

  test 'deleting the account removes push devices and the clock PIN' do
    sign_in @worker_user
    PushDevice.register!(user: @worker_user, platform: 'ios', token: 'to-delete')
    delete own_account_path, params: { confirmation: 'DELETE' }
    assert_redirected_to login_path
    assert_equal 0, PushDevice.unscoped.where(user_id: @worker_user.id).count
    assert_not @worker.reload.pin_set?
  end

  test 'nobody sees or disables another person’s device' do
    other = User.create!(tenant: @tenant, name: 'Other', email: 'other-push-worker@example.com', role: 'employee', password: 'password123')
    device = PushDevice.register!(user: other, platform: 'ios', token: 'theirs')
    sign_in @worker_user
    post unsubscribe_employee_push_path(device)
    assert_nil device.reload.disabled_at
    get employee_notification_settings_path
    assert_response :success
    assert_no_match 'last seen', response.body
  end
end
