# frozen_string_literal: true

require 'test_helper'
require_relative '../support/device_reader_fixture'
require_relative '../support/ops_log_helper'

# The attempt token and the install identifier are random, so now and then one
# contains a run of digits that CardData reads as a card number. They are
# checked by their own strict formats instead, and a payment with such a token
# or identifier must work like any other. Everything else is still scanned.
class NativeReaderIdentifiersTest < ActionDispatch::IntegrationTest
  include DeviceReaderFixture
  include OpsLogHelper
  include ActiveJob::TestHelper

  # Found by drawing random values until CardData.contains? was true (seed 20261118):
  # 1,225 of 200,000 random tokens and 245 of 200,000 random UUIDs trip it.
  TRIPPING_TOKEN = '8a7839b2c1c3d4a6c0735770c7fb31140710943470ee46f189e5b566cf4e81da'
  TRIPPING_DEVICE = '8700d2c8-4bae-d459-7250-12826382d0b4'
  VISA = '4111111111111111'

  setup do
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    prepare_device_reader_fixture(name: 'identifiers')
    sign_in(@user)
  end
  teardown do
    Current.reset
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
  end

  def json = response.parsed_body

  def in_workspace = Current.set(tenant: @tenant) { yield }

  def open_attempt
    post native_reader_attempt_path(@checkout.id), as: :json
    assert_response :success
    json['token']
  end

  def app_post(path, token, device, **extra) = post(path, params: { token: token, device_id: device, **extra }, as: :json)

  test 'the examples really do look like card data to the detector' do
    assert CardData.contains?(TRIPPING_TOKEN)
    assert CardData.contains?(TRIPPING_DEVICE)
    assert_match Pos::DeviceReaderPayment::TOKEN, TRIPPING_TOKEN
    assert_match Pos::DeviceReaderPayment::DEVICE_ID, TRIPPING_DEVICE
  end

  test 'a token and an install identifier that look card-shaped still start, report and get paid' do
    Pos::DeviceReaderPayment.stubs(:token_for).returns(TRIPPING_TOKEN)
    assert_equal TRIPPING_TOKEN, open_attempt
    app_post(start_native_reader_attempt_path, TRIPPING_TOKEN, TRIPPING_DEVICE)
    assert_response :success
    assert_equal 1166, json['amount_cents']
    app_post(result_native_reader_attempt_path, TRIPPING_TOKEN, TRIPPING_DEVICE, result: in_workspace { tap })
    assert_response :success
    assert_equal({ 'status' => 'unknown', 'reported' => true }, json)
    perform_enqueued_jobs(only: PosDeviceReaderConfirmJob)
    assert in_workspace { @checkout.reload.paid? }
    assert_not_includes in_workspace { audit_actions }, 'pos_device_reader_card_data_refused'
  end

  test 'a token and an install identifier that look card-shaped can still cancel' do
    Pos::DeviceReaderPayment.stubs(:token_for).returns(TRIPPING_TOKEN)
    open_attempt
    app_post(start_native_reader_attempt_path, TRIPPING_TOKEN, TRIPPING_DEVICE)
    assert_response :success
    app_post(cancel_native_reader_attempt_path, TRIPPING_TOKEN, TRIPPING_DEVICE)
    assert_response :success
    perform_enqueued_jobs(only: PosDeviceReaderConfirmJob)
    assert_equal 'declined', in_workspace { @checkout.reload.status }
  end

  test 'a card number sent as the token or the install identifier fails the format check and is refused' do
    token = open_attempt
    app_post(start_native_reader_attempt_path, token, DEVICE)
    before = in_workspace { attempt.attributes }
    lines = capture_ops_log do
      [[VISA, DEVICE], ["#{VISA}#{'A' * 48}", DEVICE], [token, VISA], [token, "4111-1111-1111-1111-#{'0' * 16}"],
       [token, "#{DEVICE} #{VISA}"], [[VISA], DEVICE], [token, { 'id' => VISA }]].each do |bad_token, bad_device|
        [start_native_reader_attempt_path, cancel_native_reader_attempt_path].each do |path|
          app_post(path, bad_token, bad_device)
          assert_response :unprocessable_entity, [path, bad_token, bad_device].inspect
          assert_equal Native::ReaderAttemptsController::CARD_DATA, json['error']
        end
        app_post(result_native_reader_attempt_path, bad_token, bad_device, result: { status: 'approved', amount_cents: 1166 })
        assert_response :unprocessable_entity
        assert_equal Native::ReaderAttemptsController::CARD_DATA, json['error']
      end
      # A well-formed token is not scanned, so one built around a card number is
      # just an unknown token: refused, compared by digest only, kept nowhere.
      app_post(start_native_reader_attempt_path, "#{VISA}#{'0' * 48}", DEVICE)
      assert_response :not_found
      Rails.logger.info('reader identifiers test marker')
    end
    assert lines.any?
    refute_includes ops_raw.delete(' -'), VISA
    in_workspace do
      assert_equal before, attempt.attributes
      stored = [PosPaymentAttempt.all.map(&:attributes), ActivityLog.all.map(&:attributes), OpsEvent.unscoped.map(&:attributes)].to_json
      refute_includes stored.delete(' -'), VISA
      assert_includes audit_actions, 'pos_device_reader_card_data_refused'
    end
    assert_no_enqueued_jobs(only: PosDeviceReaderConfirmJob)
  end

  test 'a card number anywhere else is still refused when the token and identifier look card-shaped' do
    Pos::DeviceReaderPayment.stubs(:token_for).returns(TRIPPING_TOKEN)
    open_attempt
    app_post(start_native_reader_attempt_path, TRIPPING_TOKEN, TRIPPING_DEVICE)
    approved = in_workspace { tap }
    capture_ops_log do
      [{ result: approved.merge('auth_code' => VISA) }, { result: approved.merge('last_four' => VISA) }, { result: approved.merge('pan' => VISA) },
       { result: approved.merge('token' => TRIPPING_TOKEN) }, { result: approved.merge('device_id' => TRIPPING_DEVICE) },
       { result: approved, note: VISA }, { result: approved, other_token: TRIPPING_TOKEN }].each do |body|
        app_post(result_native_reader_attempt_path, TRIPPING_TOKEN, TRIPPING_DEVICE, **body)
        assert_response :unprocessable_entity, body.inspect
        assert_equal Native::ReaderAttemptsController::CARD_DATA, json['error']
      end
      post native_reader_attempt_path(@checkout.id), params: { token: TRIPPING_TOKEN }, as: :json
      assert_response :unprocessable_entity, 'open takes no token, so one sent there is scanned'
    end
    refute_includes ops_raw.delete(' -'), VISA
    assert_nil in_workspace { attempt.device_reported_at }
  end

  test 'a provider reference that looks card-shaped is dropped, and the sale is still reported and confirmed' do
    token = open_attempt
    app_post(start_native_reader_attempt_path, token, DEVICE)
    approved = in_workspace { tap }
    capture_ops_log do
      app_post(result_native_reader_attempt_path, token, DEVICE, result: approved.merge('provider_reference' => VISA))
      Rails.logger.info('reader identifiers test marker')
    end
    assert_response :success
    assert_equal({ 'status' => 'unknown', 'reported' => true, 'dropped' => ['provider_reference'] }, json)
    refute_includes ops_raw.delete(' -'), VISA
    in_workspace do
      assert_equal (Pos::DeviceReaderPayment::REPORT_KEYS - ['provider_reference']).sort, attempt.device_report.keys.sort
      stored = [PosPaymentAttempt.all.map(&:attributes), ActivityLog.all.map(&:attributes), OpsEvent.unscoped.map(&:attributes)].to_json
      refute_includes stored, VISA
      assert_includes audit_actions, 'pos_device_reader_field_dropped'
    end
    perform_enqueued_jobs(only: PosDeviceReaderConfirmJob)
    in_workspace do
      assert @checkout.reload.paid?
      assert_match(/\AFAKE/, attempt.transaction_id, 'the confirmed reference comes from the provider lookup')
    end
  end

  test 'a confirmed reference from the provider that looks card-shaped does not stop the sale being paid' do
    token = open_attempt
    app_post(start_native_reader_attempt_path, token, DEVICE)
    in_workspace do
      tap
      row = Pos::DeviceReader::FakeGateway.row(attempt.invoice)
      Pos::DeviceReader::FakeGateway.update(attempt.invoice, row.merge(processor_reference: '5105105105105100'))
      assert CardData.contains?('5105105105105100')
      PosDeviceReaderConfirmJob.perform_now(attempt.id, attempt.tenant_id)
      assert @checkout.reload.paid?
      assert_equal '5105105105105100', attempt.transaction_id
    end
  end

  test 'a new attempt avoids a reference or token that looks card-shaped, and gives up politely if it cannot' do
    tripping_reference = 'RR65da21881025341189e49562'
    assert CardData.contains?(tripping_reference)
    Pos::DeviceReader.stubs(:reference).returns(tripping_reference, tripping_reference, 'RRaaaaaaaaaaaaaaaaaaaaaaaa')
    in_workspace do
      opened = Pos::DeviceReaderPayment.open!(@checkout)
      assert_equal 'RRaaaaaaaaaaaaaaaaaaaaaaaa', opened.invoice
    end
    Pos::DeviceReader.unstub(:reference)
    Pos::DeviceReaderPayment.stubs(:token_for).returns(TRIPPING_TOKEN)
    in_workspace do
      other = device_reader_checkout(display: PosDisplaySession.create!(user: @user, location: @location))
      assert_equal 'submitting', Pos::DeviceReaderPayment.open!(other).status, 'an unlucky draw every time still opens the attempt'
    end
  end
end
