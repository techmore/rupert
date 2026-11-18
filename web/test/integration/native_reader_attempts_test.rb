# frozen_string_literal: true

require 'test_helper'
require_relative '../support/device_reader_fixture'
require_relative '../support/ops_log_helper'

# The phone card reader API: session, workspace and POS permission as on the
# register; a token, a device and an amount that must match; a report that is
# only a hint; and no card data, ever. Fake provider, public test card only.
class NativeReaderAttemptsTest < ActionDispatch::IntegrationTest
  include DeviceReaderFixture
  include OpsLogHelper
  include ActiveJob::TestHelper

  VISA = '4111111111111111'
  TRACK1 = "%B#{VISA}^DOE/JOHN Q^2512101000001230000?".freeze
  TRACK2 = ";#{VISA}=25121010000012300000?".freeze

  setup do
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @cashier = User.create!(tenant: @tenant, email: 'reader-cashier@example.test', password: 'password123', role: 'cashier')
    prepare_device_reader_fixture(user: @cashier, name: 'api')
    sign_in(@cashier)
  end
  teardown do
    Current.reset
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
  end

  def json = response.parsed_body

  def open_attempt(checkout = @checkout)
    post native_reader_attempt_path(checkout.id), as: :json
    assert_response :success
    json['token']
  end

  def start(token, device: DEVICE) = post(start_native_reader_attempt_path, params: { token: token, device_id: device }, as: :json)

  def send_result(token, result, device: DEVICE, **extra)
    post result_native_reader_attempt_path, params: { token: token, device_id: device, result: result, **extra }, as: :json
  end

  def status = get(native_reader_attempt_path(@checkout.id)).then { json }

  def confirm = perform_enqueued_jobs(only: PosDeviceReaderConfirmJob)

  # Request helpers reset Current; model reads in a test need the workspace back.
  def in_workspace = Current.set(tenant: @tenant) { yield }

  test 'open, start, report and confirm: the sale is paid only after the server looks it up' do
    token = open_attempt
    assert_match(/\A[0-9a-f]{64}\z/, token)
    assert_equal ['submitting', false, 1166, 'USD'], json.values_at('status', 'reported', 'amount_cents', 'currency')
    assert_equal 'no-store', response.headers['Cache-Control']
    start(token)
    assert_response :success
    assert_equal %w[amount_cents currency expires_at reader reference tip_cents], json.keys.sort, 'the app gets only what the reader needs'
    assert_equal [1166, 101, 'USD'], json.values_at('amount_cents', 'tip_cents', 'currency')
    report = in_workspace { tap }
    send_result(token, report)
    assert_response :success
    assert_equal({ 'status' => 'unknown', 'reported' => true }, json)
    assert_equal %w[unknown unknown], status.values_at('status').push(json.dig('checkout', 'status'))
    assert_nil json['token'], 'the token is not handed out again once a result was reported'
    assert_nil json.dig('checkout', 'paid_at')
    confirm
    assert_equal 'paid', status['status']
    assert_equal 'paid', json.dig('checkout', 'status')
    assert_equal %w[Visa 1111], json.dig('checkout', 'card').values_at('brand', 'last_four')
    assert_equal 1, in_workspace { @checkout.pos_payment_attempts.count }
  end

  test 'a double tap gets the same attempt and token' do
    first = open_attempt
    assert_equal first, open_attempt
    assert_equal 1, in_workspace { @checkout.pos_payment_attempts.count }
    start(first)
    start(first)
    assert_response :success
    send_result(first, in_workspace { tap })
    post native_reader_attempt_path(@checkout.id), as: :json
    assert_response :success
    assert_equal ['unknown', nil], json.values_at('status', 'token')
    confirm
    post native_reader_attempt_path(@checkout.id), as: :json
    assert_equal 'paid', json['status'], 'a tap after payment shows the paid attempt and opens nothing'
    assert_equal 1, in_workspace { @checkout.pos_payment_attempts.count }
  end

  test 'a duplicate report over HTTP is accepted and changes nothing' do
    token = open_attempt
    start(token)
    report = in_workspace { tap }
    send_result(token, report)
    assert_no_enqueued_jobs(only: PosDeviceReaderConfirmJob) do
      perform_enqueued_jobs(only: PosDeviceReaderConfirmJob)
      send_result(token, report)
      assert_response :success
      send_result(token, { status: 'declined' })
      assert_response :success
    end
    assert_equal 'paid', status['status']
    assert_equal 1, in_workspace { audit_actions.count('pos_sandbox_checkout_completed') }
  end

  test 'a wrong token, a wrong device and a wrong amount are all refused' do
    token = open_attempt
    start('0' * 64)
    assert_response :not_found
    start('not-a-token')
    assert_response :not_found
    start(token)
    start(token, device: OTHER_DEVICE)
    assert_response :forbidden
    approved = in_workspace { tap }
    send_result('f' * 64, approved)
    assert_response :not_found
    send_result(token, approved, device: OTHER_DEVICE)
    assert_response :forbidden
    assert_no_enqueued_jobs(only: PosDeviceReaderConfirmJob)
    send_result(token, approved.merge('amount_cents' => 1165))
    assert_response :unprocessable_entity
    assert_match(/does not match/, json['error'])
    assert_equal ['submitting', false], status.values_at('status', 'reported'), 'nothing from a refused report was recorded'
    assert_enqueued_jobs 1, only: PosDeviceReaderConfirmJob
    post cancel_native_reader_attempt_path, params: { token: token, device_id: OTHER_DEVICE }, as: :json
    assert_response :forbidden
  end

  test 'another workspace cannot use the token or see the checkout' do
    token = open_attempt
    start(token)
    other = create_workspace('Other reader workspace', current: false, status: 'active')
    outsider = User.create!(tenant: other, email: 'reader-outsider@example.test', password: 'password123', role: 'admin')
    Current.set(tenant: other) { FeatureFlag.set(:device_reader, true) }
    delete logout_path
    sign_in(outsider)
    start(token)
    assert_response :not_found
    send_result(token, { status: 'approved', amount_cents: 1166 })
    assert_response :not_found
    post cancel_native_reader_attempt_path, params: { token: token, device_id: DEVICE }, as: :json
    assert_response :not_found
    post native_reader_attempt_path(@checkout.id), as: :json
    assert_response :not_found
    get native_reader_attempt_path(@checkout.id)
    assert_response :not_found
    assert_equal 'submitting', in_workspace { attempt.status }
    assert_nil in_workspace { attempt.device_reported_at }
  end

  test 'POS permission is required, and a cashier cannot touch another cashier\'s checkout' do
    token = open_attempt
    start(token)
    delete logout_path
    reader = User.create!(tenant: @tenant, email: 'reader-no-pos@example.test', password: 'password123', role: 'reader')
    sign_in(reader)
    post native_reader_attempt_path(@checkout.id), as: :json
    assert_response :forbidden
    get native_reader_attempt_path(@checkout.id)
    assert_response :forbidden
    send_result(token, { status: 'approved', amount_cents: 1166 })
    assert_response :forbidden
    post cancel_native_reader_attempt_path, params: { token: token, device_id: DEVICE }, as: :json
    assert_response :forbidden
    delete logout_path
    colleague = User.create!(tenant: @tenant, email: 'reader-colleague@example.test', password: 'password123', role: 'cashier')
    sign_in(colleague)
    send_result(token, { status: 'approved', amount_cents: 1166 })
    assert_response :not_found
    get native_reader_attempt_path(@checkout.id)
    assert_response :not_found
    delete logout_path
    sign_in(users(:regular_user))
    get native_reader_attempt_path(@checkout.id)
    assert_response :success, 'an administrator can see it, as on the register'
    assert_equal ['submitting', false], json.values_at('status', 'reported')
  end

  test 'staff accounts with POS access may take a payment; signed-out requests are sent to sign in' do
    delete logout_path
    post native_reader_attempt_path(@checkout.id), as: :json
    assert_redirected_to login_path
    post result_native_reader_attempt_path, params: { token: 'f' * 64, device_id: DEVICE, result: { status: 'approved' } }, as: :json
    assert_redirected_to login_path
    employee = User.create!(tenant: @tenant, email: 'reader-employee@example.test', password: 'password123', role: 'employee')
    in_workspace { @checkout.update!(user: employee, pos_display_session: PosDisplaySession.create!(user: employee, location: @location)) }
    sign_in(employee)
    token = open_attempt
    start(token)
    assert_response :success
  end

  test 'cancel before a result is confirmed by lookup; after a result it is refused' do
    token = open_attempt
    start(token)
    post cancel_native_reader_attempt_path, params: { token: token, device_id: DEVICE }, as: :json
    assert_response :success
    assert_equal 'unknown', json['status']
    confirm
    assert_equal %w[declined declined], [status['status'], json.dig('checkout', 'status')]
    assert_equal Pos::DeviceReaderPayment::CANCELED, json['message']
    token = open_attempt
    start(token)
    send_result(token, in_workspace { tap })
    post cancel_native_reader_attempt_path, params: { token: token, device_id: DEVICE }, as: :json
    assert_response :unprocessable_entity
    confirm
    assert_equal 'paid', status['status']
  end

  test 'a full card number or track data anywhere in a request is refused, saved nowhere and never logged' do
    token = open_attempt
    start(token)
    approved = in_workspace { tap }
    before = in_workspace { attempt.attributes }
    lines = capture_ops_log do
      [
        { result: approved.merge('provider_reference' => VISA) },
        { result: approved.merge('auth_code' => '4111 1111 1111 1111') },
        { result: approved.merge('amount_cents' => VISA.to_i) },
        { result: approved.merge('last_four' => VISA) },
        { result: approved.merge('track2' => TRACK2) },
        { result: approved.merge('emv' => { 'tag57' => "#{VISA}D25121010000012300000" }) },
        { result: approved, card_number: VISA },
        { result: approved, notes: ["swiped #{TRACK1}"] },
        { result: approved, VISA => 'x' },
        { result: approved, device_id: "install-#{VISA}" }
      ].each do |body|
        post result_native_reader_attempt_path, params: { token: token, device_id: DEVICE }.merge(body), as: :json
        assert_response :unprocessable_entity, body.inspect
        assert_equal Native::ReaderAttemptsController::CARD_DATA, json['error']
        refute_includes response.body.delete(' -'), VISA
      end
      post start_native_reader_attempt_path, params: { token: token, device_id: DEVICE, pan: VISA }, as: :json
      assert_response :unprocessable_entity
      post cancel_native_reader_attempt_path, params: { token: token, device_id: DEVICE, track1: TRACK1 }, as: :json
      assert_response :unprocessable_entity
      post native_reader_attempt_path(@checkout.id), params: { cvv: '987', card: VISA }, as: :json
      assert_response :unprocessable_entity
      get native_reader_attempt_path(@checkout.id, pan: VISA)
      assert_response :unprocessable_entity
      post "#{result_native_reader_attempt_path}?track2=#{CGI.escape(TRACK2)}", params: { token: token, device_id: DEVICE, result: approved }, as: :json
      assert_response :unprocessable_entity
      Rails.logger.info('reader attempts card data test marker')
    end
    assert lines.any?
    assert_includes ops_raw, 'reader_attempts'
    flat = ops_raw.delete(' -')
    refute_includes flat, VISA
    refute_includes ops_raw, 'DOE/JOHN'
    refute_includes ops_raw, '2512101'
    assert_no_enqueued_jobs(only: PosDeviceReaderConfirmJob)
    in_workspace do
      assert_equal before, attempt.attributes, 'nothing from a refused request reached the attempt'
      stored = [PosPaymentAttempt.all.map(&:attributes), ActivityLog.all.map(&:attributes), OpsEvent.unscoped.map(&:attributes)].to_json
      refute_includes stored.delete(' -'), VISA
      refute_includes stored, 'DOE/JOHN'
      assert_includes audit_actions, 'pos_device_reader_card_data_refused'
    end
    send_result(token, approved)
    assert_response :success
  end

  test 'fields outside the short list are refused, including harmless-looking ones' do
    token = open_attempt
    start(token)
    approved = in_workspace { tap }
    [{ result: approved.merge('first_six' => '411111') }, { result: approved.merge('cardholder_name' => 'PAT CARDHOLDER') },
     { result: approved.merge('expiry' => '1229') }, { result: approved.merge('token' => 'card-token-secret') },
     { result: approved, amount_cents: 1 }, { result: approved, checkout_id: 1 }, { result: approved.merge('status' => 'paid') },
     { result: 'approved' }, {}].each do |body|
      post result_native_reader_attempt_path, params: { token: token, device_id: DEVICE }.merge(body), as: :json
      assert_response :unprocessable_entity, body.inspect
    end
    post native_reader_attempt_path(@checkout.id), params: { amount_cents: 1 }, as: :json
    assert_response :unprocessable_entity, 'the page cannot name an amount'
    get native_reader_attempt_path(@checkout.id, amount_cents: 1)
    assert_response :unprocessable_entity
    post start_native_reader_attempt_path, params: { token: token, device_id: DEVICE, amount_cents: 1 }, as: :json
    assert_response :unprocessable_entity
    in_workspace do
      assert_nil attempt.device_reported_at
      stored = PosPaymentAttempt.all.map(&:attributes).to_json
      ['411111', 'PAT CARDHOLDER', 'card-token-secret', '1229'].each { |value| refute_includes stored, value }
    end
  end

  test 'a refund or void of a reader payment needs sales.write and a reason, through the existing reversal route' do
    token = open_attempt
    start(token)
    send_result(token, in_workspace { tap })
    confirm
    post reverse_pos_checkout_path(@checkout.id), params: { amount: '11.66', reason: 'no' }
    assert_match(/reason/, flash[:alert])
    assert_empty in_workspace { PosCardReversal.where(pos_checkout_id: @checkout.id).to_a }
    post reverse_pos_checkout_path(@checkout.id), params: { amount: '5.00', reason: 'Customer return' }
    assert_match(/Refunded 5.00/, flash[:notice])
    delete logout_path
    employee = User.create!(tenant: @tenant, email: 'reader-refund-employee@example.test', password: 'password123', role: 'employee')
    in_workspace { PosCheckout.where(id: @checkout.id).update_all(user_id: employee.id) }
    sign_in(employee)
    post reverse_pos_checkout_path(@checkout.id), params: { amount: '1.00', reason: 'Customer return' }
    assert_equal "You don't have permission to do that.", flash[:alert]
    assert_equal [500], in_workspace { PosCardReversal.where(pos_checkout_id: @checkout.id).pluck(:amount_cents) }
    delete logout_path
    sign_in(users(:regular_user))
    post reverse_pos_checkout_path(@checkout.id), params: { amount: '6.66', reason: 'Customer return' }
    assert_match(/Refunded 6.66/, flash[:notice])
    assert_equal %w[refund refund], in_workspace { PosCardReversal.succeeded.where(pos_checkout_id: @checkout.id).pluck(:kind) }
  end
end
