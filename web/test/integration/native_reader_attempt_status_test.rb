# frozen_string_literal: true

require 'test_helper'
require_relative '../support/device_reader_fixture'
require_relative '../support/ops_log_helper'

# POST /native/reader_attempts/status: the phone that started an attempt reads
# the server-confirmed outcome by token. A few fields, nothing from the
# receipt, and reading it changes nothing.
class NativeReaderAttemptStatusTest < ActionDispatch::IntegrationTest
  include DeviceReaderFixture
  include OpsLogHelper
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  KEYS = %w[amount_cents message needs_review reported status].freeze
  VISA = '4111111111111111'

  setup do
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @cashier = User.create!(tenant: @tenant, email: 'status-cashier@example.test', password: 'password123', role: 'cashier')
    prepare_device_reader_fixture(user: @cashier, name: 'status')
    sign_in(@cashier)
    post native_reader_attempt_path(@checkout.id), as: :json
    @token = response.parsed_body['token']
  end
  teardown do
    Current.reset
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
  end

  def json = response.parsed_body

  def in_workspace = Current.set(tenant: @tenant) { yield }

  def app_post(path, token: @token, device: DEVICE, **extra) = post(path, params: { token: token, device_id: device, **extra }, as: :json)

  def poll(**options)
    app_post(status_native_reader_attempt_path, **options)
    json
  end

  def confirm = perform_enqueued_jobs(only: PosDeviceReaderConfirmJob)

  def assert_state(status, reported:, needs_review: false, message: nil)
    body = poll
    assert_response :success
    assert_equal KEYS, body.keys.sort, 'only the five fields, nothing from the receipt'
    assert_equal({ 'status' => status, 'reported' => reported, 'needs_review' => needs_review, 'message' => message, 'amount_cents' => 1166 }, body)
    assert_equal 'no-store', response.headers['Cache-Control']
  end

  test 'submitting, then awaiting confirmation, then paid only once the server confirmed it' do
    app_post(start_native_reader_attempt_path)
    assert_state 'submitting', reported: false
    app_post(result_native_reader_attempt_path, result: in_workspace { tap })
    assert_state 'unknown', reported: true
    assert_not in_workspace { @checkout.reload.paid? }, 'the report did not pay it, and neither did reading the status'
    confirm
    assert_state 'paid', reported: true
    assert in_workspace { @checkout.reload.paid? }
    card = in_workspace { @checkout.receipt[:card] }
    assert_equal %w[Visa 1111 A1B2C3], card.values_at(:brand, :last_four, :auth_code), 'the receipt has card details'
    [card[:last_four], card[:auth_code], card[:brand], card[:transaction_id], in_workspace { attempt.invoice }, @checkout.reference, @token].each do |value|
      assert_not_includes response.body, value, 'but the status answer carries none of them'
    end
  end

  test 'a phone report of approved that the provider does not confirm is never shown as paid' do
    app_post(start_native_reader_attempt_path)
    app_post(result_native_reader_attempt_path, result: { status: 'approved', amount_cents: 1166 })
    confirm
    assert_state 'unknown', reported: true
    travel 6.minutes do
      PosPaymentReconciliationJob.any_instance.stubs(:lock_path).returns(Pathname(Dir.mktmpdir('pos-reconciliation-lock')).join('reconciliation.lock'))
      PosPaymentReconciliationJob.perform_now
      assert_state 'unknown', reported: true, needs_review: true, message: Pos::DeclineReason::REVIEW
    end
  end

  test 'declined and cancelled show the cashier wording' do
    app_post(start_native_reader_attempt_path)
    app_post(result_native_reader_attempt_path, result: in_workspace { tap(:declined) })
    confirm
    assert_state 'declined', reported: true, message: Pos::DeviceReaderPayment::DECLINED
    post native_reader_attempt_path(@checkout.id), as: :json
    second = json['token']
    app_post(start_native_reader_attempt_path, token: second)
    app_post(cancel_native_reader_attempt_path, token: second)
    confirm
    assert_equal ['declined', Pos::DeviceReaderPayment::CANCELED], poll(token: second).values_at('status', 'message')
    assert_equal 'declined', poll['status'], 'the first token still reads its own attempt'
  end

  test 'an approval for a different amount shows as held for review' do
    app_post(start_native_reader_attempt_path)
    wrong = in_workspace { tap(:wrong_amount) }
    app_post(result_native_reader_attempt_path, result: wrong)
    assert_response :unprocessable_entity
    confirm
    assert_state 'unknown', reported: false, needs_review: true, message: Pos::DeclineReason::REVIEW
  end

  test 'a sale resolved by the sweep after the app was killed is readable after a relaunch' do
    app_post(start_native_reader_attempt_path)
    in_workspace do
      tap
      Pos::DeviceReaderPayment.reconcile!(attempt)
    end
    assert_state 'paid', reported: false
  end

  test 'only the device that started the attempt may read it, and only once it has started' do
    assert_equal 'This payment was started on another device.', poll['error']
    assert_response :forbidden
    app_post(start_native_reader_attempt_path)
    poll(device: OTHER_DEVICE)
    assert_response :forbidden
    assert_equal ['error'], json.keys
    poll(device: DEVICE.upcase)
    assert_response :success
    poll(device: 'not-a-uuid')
    assert_response :unprocessable_entity
    post status_native_reader_attempt_path, params: { token: @token }, as: :json
    assert_response :unprocessable_entity
  end

  test 'an unknown token, another workspace, another cashier and a missing permission are refused' do
    app_post(start_native_reader_attempt_path)
    poll(token: 'f' * 64)
    assert_response :not_found
    poll(token: 'short')
    assert_response :not_found
    post status_native_reader_attempt_path, params: { device_id: DEVICE }, as: :json
    assert_response :not_found
    delete logout_path
    poll
    assert_redirected_to login_path
    colleague = User.create!(tenant: @tenant, email: 'status-colleague@example.test', password: 'password123', role: 'cashier')
    sign_in(colleague)
    poll
    assert_response :not_found
    delete logout_path
    reader = User.create!(tenant: @tenant, email: 'status-no-pos@example.test', password: 'password123', role: 'reader')
    sign_in(reader)
    poll
    assert_response :forbidden
    delete logout_path
    other = create_workspace('Other status workspace', current: false, status: 'active')
    outsider = User.create!(tenant: other, email: 'status-outsider@example.test', password: 'password123', role: 'admin')
    Current.set(tenant: other) { FeatureFlag.set(:device_reader, true) }
    sign_in(outsider)
    poll
    assert_response :not_found
  end

  test 'the feature flag off answers 404' do
    app_post(start_native_reader_attempt_path)
    in_workspace { FeatureFlag.set(:device_reader, false) }
    poll
    assert_response :not_found
    assert_empty response.body
  end

  test 'card data and extra fields are refused, and the token never appears in a URL or the log' do
    app_post(start_native_reader_attempt_path)
    lines = capture_ops_log do
      poll
      assert_response :success
      poll(pan: VISA)
      assert_response :unprocessable_entity
      assert_equal Native::ReaderAttemptsController::CARD_DATA, json['error']
      poll(device: VISA)
      assert_response :unprocessable_entity
      poll(token: VISA)
      assert_response :unprocessable_entity
      poll(amount_cents: 1)
      assert_response :unprocessable_entity
      post "#{status_native_reader_attempt_path}?token=#{@token}", params: { device_id: DEVICE }, as: :json
      assert_response :unprocessable_entity, 'the token is not accepted in the query string'
      Rails.logger.info('reader status test marker')
    end
    assert lines.any?
    assert_includes ops_raw, '/native/reader_attempts/status'
    assert_not_includes ops_raw, @token
    assert_not_includes ops_raw.delete(' -'), VISA
    assert_raises(ActionController::RoutingError) { Rails.application.routes.recognize_path('/native/reader_attempts/status', method: :get) }
  end

  test 'repeated polling changes nothing, looks nothing up and writes no audit entries' do
    app_post(start_native_reader_attempt_path)
    app_post(result_native_reader_attempt_path, result: in_workspace { tap })
    before = in_workspace { [attempt.attributes, @checkout.reload.attributes, ActivityLog.count, provider_lookups] }
    assert_no_enqueued_jobs do
      25.times { assert_equal 'unknown', poll['status'] }
    end
    assert_equal before, in_workspace { [attempt.attributes, @checkout.reload.attributes, ActivityLog.count, provider_lookups] }
    confirm
    paid = in_workspace { [attempt.attributes, ActivityLog.count, provider_lookups] }
    assert_no_enqueued_jobs do
      25.times { assert_equal 'paid', poll['status'] }
    end
    assert_equal paid, in_workspace { [attempt.attributes, ActivityLog.count, provider_lookups] }
    assert_equal 1, in_workspace { audit_actions.count('pos_sandbox_checkout_completed') }
  end
end
