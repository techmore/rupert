# frozen_string_literal: true

require 'test_helper'

# Push delivery to the iPhone app (APNs, stubbed at the apnotic connection) and the installed web
# app (Web Push, stubbed at the HTTP layer). Dead devices are disabled, never deleted.
class PushNotifierTest < ActiveSupport::TestCase
  APNS_ENV = { 'APNS_KEY_ID' => 'ABC123DEFG', 'APNS_TEAM_ID' => 'TEAM123456', 'APNS_KEY_P8' => "-----BEGIN PRIVATE KEY-----\nMIGT\n-----END PRIVATE KEY-----",
               'APNS_TOPIC' => 'com.rupertpos.Rupert', 'APNS_ENVIRONMENT' => 'sandbox' }.freeze
  VAPID_ENV = { 'VAPID_PUBLIC_KEY' => 'BDd3_hVL9fZi9Ybo2UUzA284WG5FZR30_95YeZJsiApwXKpNcF1rRPF3foIiBHXRdJI2Qhumhf6_LFTeZaNndIo',
                'VAPID_PRIVATE_KEY' => 'xx', 'VAPID_SUBJECT' => 'mailto:support@example.com' }.freeze

  FakeResponse = Struct.new(:status, :body) do
    def ok? = status.to_s == '200'
  end

  class FakeConnection
    attr_reader :pushed

    def initialize(responses)
      @responses = responses
      @pushed = []
    end

    def push(notification)
      @pushed << notification
      @responses.shift
    end

    def close; end
  end

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @user = users(:regular_user)
    @notification = Notification.create!(user_id: @user.id, kind: 'schedule_posted', title: 'Your schedule is posted', body: '3 shifts', url: '/employee/schedule')
  end

  teardown { Current.reset }

  test 'nothing is configured by default so the job is never enqueued' do
    with_env(APNS_KEYS_BLANK) do
      assert_not PushNotifier.configured?
      assert_not PushDeliveryJob.enabled?
    end
  end

  test 'apns sends to every active iPhone and disables tokens the provider rejects for good' do
    good = PushDevice.register!(user: @user, platform: 'ios', token: 'good-token')
    dead = PushDevice.register!(user: @user, platform: 'ios', token: 'dead-token')
    PushDevice.register!(user: @user, platform: 'ios', token: 'off-token').disable!('earlier')
    connection = FakeConnection.new([FakeResponse.new('200', {}), FakeResponse.new('410', { 'reason' => 'Unregistered' })])
    with_env(APNS_ENV) do
      assert PushNotifier.configured?
      assert PushDeliveryJob.enabled?
      Apnotic::Connection.expects(:development).returns(connection)
      result = PushNotifier.deliver(@notification)
      assert_equal 1, result.sent
      assert_equal 1, result.disabled
      assert_equal 0, result.failed
    end
    assert_equal 2, connection.pushed.size
    push = connection.pushed.first
    assert_equal 'com.rupertpos.Rupert', push.topic
    assert_equal({ title: 'Your schedule is posted', body: '3 shifts' }, push.alert)
    assert_equal '/employee/schedule', push.custom_payload[:url]
    assert_equal 'schedule_posted', push.thread_id
    assert_equal 1, push.badge, 'badge is the unread count'
    assert_nil good.reload.disabled_at
    assert_equal 'Unregistered', dead.reload.failure_reason
    assert dead.disabled_at.present?
  end

  test 'apns errors are counted as failures and never raise' do
    PushDevice.register!(user: @user, platform: 'ios', token: 'any-token')
    with_env(APNS_ENV) do
      Apnotic::Connection.expects(:development).raises(SocketError.new('no route'))
      result = PushNotifier.deliver(@notification)
      assert_equal 1, result.failed
    end
  end

  test 'web push posts the payload to the subscription endpoint and drops gone subscriptions' do
    alive = PushDevice.register!(user: @user, platform: 'web', token: 'https://push.example/alive', keys: { 'p256dh' => 'p', 'auth' => 'a' })
    gone = PushDevice.register!(user: @user, platform: 'web', token: 'https://push.example/gone', keys: { 'p256dh' => 'p', 'auth' => 'a' })
    with_env(VAPID_ENV) do
      WebPush.expects(:payload_send).twice.with { |args| args[:endpoint] == alive.token || args[:endpoint] == gone.token }
        .returns(nil).then.raises(WebPush::ExpiredSubscription.new(Struct.new(:code, :body).new('410', ''), 'push.example'))
      result = PushNotifier.deliver(@notification)
      assert_equal 1, result.sent
      assert_equal 1, result.disabled
    end
    assert_nil alive.reload.disabled_at
    assert_equal 'ExpiredSubscription', gone.reload.failure_reason
  end

  test 'the delivery job runs inside the notification workspace' do
    PushDevice.register!(user: @user, platform: 'ios', token: 'job-token')
    with_env(APNS_ENV) do
      Apnotic::Connection.expects(:development).returns(FakeConnection.new([FakeResponse.new('200', {})]))
      Current.reset
      PushDeliveryJob.perform_now(@notification.id)
    end
  end

  APNS_KEYS_BLANK = (PushNotifier::APNS_KEYS + PushNotifier::VAPID_KEYS).index_with { nil }.freeze

  private

  def with_env(values)
    saved = values.keys.index_with { |key| ENV.fetch(key, nil) }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
