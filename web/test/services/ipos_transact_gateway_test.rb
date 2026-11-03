# frozen_string_literal: true

require 'test_helper'

# Stubs iPOS Transact (sandbox). Shapes follow docs.ipospays.com
# ipos-transact/sale/sale-paymenttoken/post, read 2026-11-03.
class IposTransactGatewayTest < ActiveSupport::TestCase
  URL = 'https://payment.ipospays.tech/api/v3/iposTransact'
  TPN = '123456789012'
  TOKEN = 'sandbox-transact-token-0001'
  PAYMENT_TOKEN = '65564fda-9c7e-46fd-9eca-40caff6e53c6'

  setup do
    @gateway = Pos::IposTransactGateway.new(tpn: TPN, token: TOKEN)
    @reference = Pos::IposTransactGateway.reference
    @requests = []
  end

  def stub_sale(code: '200', echo: nil, status: 200, extra: {})
    stub_request(:post, URL).to_return do |request|
      @requests << request
      body = JSON.parse(request.body)
      ref = echo || body.dig('merchantAuthentication', 'transactionReferenceId')
      { status: status, headers: { 'Content-Type' => 'application/json' },
        body: { iposhpresponse: { responseCode: code, responseMessage: code == '200' ? 'Successful' : 'Declined',
          errResponseCode: code == '200' ? '00' : '05', transactionReferenceId: ref, transactionType: '1',
          transactionId: 'TX123', amount: '12.50', totalAmount: '12.50', responseApprovalCode: 'A1B2C3',
          rrn: '123456789012', batchNumber: '007', cardNumber: '4111111111111111', cardToken: 'secret' }.merge(extra) }.to_json }
    end
  end

  test 'production and malformed credentials are refused' do
    assert_raises(Pos::Error) { Pos::IposTransactGateway.new(tpn: TPN, token: TOKEN, environment: 'production') }
    assert_raises(Pos::Error) { Pos::IposTransactGateway.new(tpn: '123', token: TOKEN) }
    assert_raises(Pos::Error) { Pos::IposTransactGateway.url('production') }
  end

  test 'a sale sends the token header, cents amount and single-use payment token' do
    stub_sale
    result = @gateway.sale(reference: @reference, payment_token_id: PAYMENT_TOKEN, amount_cents: 1250)
    request = @requests.last
    body = JSON.parse(request.body)
    assert_equal TOKEN, request.headers['Token']
    assert_equal TPN, body.dig('merchantAuthentication', 'merchantId')
    assert_equal @reference, body.dig('merchantAuthentication', 'transactionReferenceId')
    assert_equal 1, body.dig('transactionRequest', 'transactionType')
    assert_equal '1250', body.dig('transactionRequest', 'amount')
    assert_equal PAYMENT_TOKEN, body.dig('transactionRequest', 'paymentTokenId')
    assert_equal false, body.dig('preferences', 'requestCardToken')
    assert result.approved?
    assert_equal 1250, result.total_cents
    assert_equal 'A1B2C3', result.approval_code
    assert_equal '123456789012', result.rrn
  end

  test 'card data in a response is never kept' do
    stub_sale
    result = @gateway.sale(reference: @reference, payment_token_id: PAYMENT_TOKEN, amount_cents: 1250)
    assert_not_includes result.to_h.values.map(&:to_s).join, '4111111111111111'
    assert_not_includes result.to_h.values.map(&:to_s).join, 'secret'
  end

  test 'a decline is declined and an approval for another reference is unknown' do
    stub_sale(code: '400')
    assert @gateway.sale(reference: @reference, payment_token_id: PAYMENT_TOKEN, amount_cents: 1250).declined?
    WebMock.reset!
    stub_sale(echo: 'SOMEONEELSE')
    assert_equal 'unknown', @gateway.sale(reference: @reference, payment_token_id: PAYMENT_TOKEN, amount_cents: 1250).outcome
  end

  test 'a lost response raises once and is never retried' do
    stub_request(:post, URL).to_timeout
    error = assert_raises(Pos::Error) { @gateway.sale(reference: @reference, payment_token_id: PAYMENT_TOKEN, amount_cents: 1250) }
    assert_includes error.message, 'portal'
    assert_requested :post, URL, times: 1
  end

  test 'bad inputs never reach Dejavoo' do
    assert_raises(Pos::Error) { @gateway.sale(reference: 'bad ref!', payment_token_id: PAYMENT_TOKEN, amount_cents: 1250) }
    assert_raises(Pos::Error) { @gateway.sale(reference: @reference, payment_token_id: '4111111111111111<', amount_cents: 1250) }
    assert_raises(Pos::Error) { @gateway.sale(reference: @reference, payment_token_id: PAYMENT_TOKEN, amount_cents: 0) }
    assert_not_requested :post, URL
  end
end
