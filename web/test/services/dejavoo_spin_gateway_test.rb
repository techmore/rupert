# frozen_string_literal: true

require 'test_helper'
require_relative '../support/dejavoo_spin_fixture'

class DejavooSpinGatewayTest < ActiveSupport::TestCase
  include DejavooSpinFixture

  setup do
    Current.tenant = tenants(:default_tenant)
    @location = Location.create!(source: 'ctrax', externalId: 'dejavoo-fixture/1', name: 'Dejavoo sandbox fixture')
    @setting = PosSetting.create!(location: @location, gateway_provider: 'dejavoo_spin', environment: 'sandbox', credentials_json: dejavoo_credentials)
    @gateway = Pos::DejavooSpinGateway.new(@setting)
    prepare_dejavoo_fixture
  end
  teardown { Current.reset }

  test 'settings accept only a sandbox Dejavoo setup with well-formed TPN and auth key' do
    production = PosSetting.new(location: Location.create!(source: 'ctrax', externalId: 'dejavoo-fixture/2', name: 'Second'),
      gateway_provider: 'dejavoo_spin', environment: 'production', credentials_json: dejavoo_credentials)
    assert_not production.valid?
    assert_includes production.errors[:environment].join, 'sandbox'
    @setting.credentials_json = { tpn: 'short', auth_key: AUTH_KEY }.to_json
    assert_not @setting.valid?
    @setting.credentials_json = { tpn: TPN, auth_key: AUTH_KEY, security_key: 'x' * 20 }.to_json
    assert_not @setting.valid?
    assert_raises(Pos::Error) { Pos::DejavooSpinGateway.url('production', 'v2/Payment/Sale') }
  end

  test 'a sale sends credentials in the body and asks the terminal not to print or return receipts' do
    reference = Pos::DejavooSpinGateway.reference
    result = @gateway.sale(reference: reference, amount_cents: 1065, tip_cents: 101, invoice: 'abc123')
    path, body = @spin_requests.last
    assert_equal 'v2/Payment/Sale', path
    assert_equal %w[Amount Authkey CaptureSignature GetExtendedData GetReceipt InvoiceNumber PaymentType PrintReceipt ReferenceId SPInProxyTimeout TipAmount Tpn], body.keys.sort
    assert_in_delta 10.65, body['Amount']
    assert_in_delta 1.01, body['TipAmount']
    assert_equal 'Credit', body['PaymentType']
    assert_equal reference, body['ReferenceId']
    assert_equal 'No', body['GetReceipt']
    assert_equal 'No', body['PrintReceipt']
    assert_equal 90, body['SPInProxyTimeout']
    assert result.approved?
    assert_equal 1166, result.total_cents
    assert_equal 101, result.tip_cents
    assert_equal 'Visa', result.card_brand
    assert_equal '1111', result.card_last_four
    assert_equal 'Contactless', result.entry_type
    assert_equal 'A1B2C3', result.auth_code
    assert_equal '987654321', result.processor_reference
  end

  test 'only whitelisted fields survive parsing: no card number, BIN, name, expiry, token, receipt or EMV data' do
    result = @gateway.sale(reference: Pos::DejavooSpinGateway.reference, amount_cents: 1166)
    kept = result.to_h.to_json
    ['4111111111111111', '411111', 'PAT CARDHOLDER', '1229', 'card-token-secret', 'ipos-token-secret', 'A0000000031010', 'CUSTOMER COPY', 'iVBORw0KGgo'].each do |secret|
      assert_not_includes kept, secret
    end
  end

  test 'status codes map to what they mean for money' do
    {
      approved: 'approved', partial: 'partial', declined: 'declined', canceled: 'declined',
      offline: 'unavailable', bad_key: 'rejected', timed_out: 'unknown'
    }.each do |mode, outcome|
      @spin_sale_mode = mode
      assert_equal outcome, @gateway.sale(reference: Pos::DejavooSpinGateway.reference, amount_cents: 500).outcome, mode.to_s
    end
    assert_equal 'unknown', Pos::DejavooSpinGateway::OUTCOMES.fetch('1999', 'unknown')
    assert_equal 'unknown', Pos::DejavooSpinGateway::OUTCOMES.fetch('1011', 'unknown'), 'a duplicate reference must be checked, not assumed'
  end

  test 'an approval that does not name our reference is not trusted' do
    stub_request(:post, "#{HOST}/v2/Payment/Sale").to_return(spin_json('0000', 'RDsomeoneelse'))
    result = @gateway.sale(reference: Pos::DejavooSpinGateway.reference, amount_cents: 1166)
    assert_equal 'unknown', result.outcome
    assert_not result.charged?
  end

  test 'transport failures and unexpected bodies raise without a verdict' do
    [{ status: 500, body: '{}' }, { status: 200, body: '<html>busy</html>' }, { status: 200, body: '{"GeneralResponse":{"StatusCode":"ok"}}' }, { status: 200, body: '[]' }].each do |reply|
      stub_request(:post, "#{HOST}/v2/Payment/Sale").to_return(reply)
      error = assert_raises(Pos::Error) { @gateway.sale(reference: Pos::DejavooSpinGateway.reference, amount_cents: 100) }
      assert_match(/could not be verified/, error.message)
    end
    stub_request(:post, "#{HOST}/v2/Payment/Sale").to_raise(Net::ReadTimeout)
    assert_raises(Pos::Error) { @gateway.sale(reference: Pos::DejavooSpinGateway.reference, amount_cents: 100) }
  end

  test 'input is checked before anything is sent' do
    assert_raises(Pos::Error) { @gateway.sale(reference: 'bad ref!', amount_cents: 100) }
    assert_raises(Pos::Error) { @gateway.sale(reference: 'RD1', amount_cents: 0) }
    assert_raises(Pos::Error) { @gateway.sale(reference: 'RD1', amount_cents: 100, tip_cents: 101) }
    assert_raises(Pos::Error) { @gateway.sale(reference: 'RD1', amount_cents: 100, payment_type: 'EBT_Food') }
    assert_empty @spin_requests
  end

  test 'verify checks credentials and terminal reachability without running a card' do
    assert @gateway.verify!
    assert_equal ['v2/Payment/Status'], spin_paths
    stub_request(:post, "#{HOST}/v2/Payment/Status").to_return(spin_json('2001', nil))
    assert_match(/not connected/, assert_raises(Pos::Error) { @gateway.verify! }.message)
    stub_request(:post, "#{HOST}/v2/Payment/Status").to_return(spin_json('2002', nil))
    assert_match(/refused the TPN/, assert_raises(Pos::Error) { @gateway.verify! }.message)
  end

  test 'void, refund and tip adjust use their SPIn paths and the original reference' do
    reference = Pos::DejavooSpinGateway.reference
    @gateway.sale(reference: reference, amount_cents: 1166)
    assert @gateway.void(reference: reference, amount_cents: 1166).approved?
    assert_equal ['v2/Payment/Void', reference], [@spin_requests.last.first, @spin_requests.last.last['ReferenceId']]
    stub_request(:post, "#{HOST}/v2/Payment/Return").to_return(spin_json('0000', 'RDreturn1', type: 'Return'))
    assert @gateway.refund(reference: 'RDreturn1', amount_cents: 500).approved?
    stub_request(:post, "#{HOST}/v2/Payment/TipAdjust").to_return(spin_json('0000', reference, type: 'TipAdjust'))
    assert @gateway.tip_adjust(reference: reference, amount_cents: 1065, tip_cents: 200).approved?
  end

  test 'settle returns batch totals in cents' do
    rows = @gateway.settle
    assert_equal [{ batch_number: '42', count: 3, sale_cents: 3050, return_cents: 500, void_cents: 0, total_cents: 2550 }], rows
    assert_equal 'Close', @spin_requests.last.last['SettlementType']
  end

  test 'a gateway for another provider or workspace is refused' do
    nmi = PosSetting.create!(location: Location.create!(source: 'ctrax', externalId: 'dejavoo-fixture/3', name: 'NMI'), gateway_provider: 'nmi', credentials_json: '{}')
    assert_raises(Pos::Error) { Pos::DejavooSpinGateway.new(nmi) }
    assert_raises(Pos::Error) { Pos::DejavooSpinGateway.new(PosSetting.new(gateway_provider: 'dejavoo_spin')) }
  end
end
