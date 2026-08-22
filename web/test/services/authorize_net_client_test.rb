# frozen_string_literal: true

require 'test_helper'

class AuthorizeNetClientTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(name: 'Auth Co', subdomain: 'authco')
    Current.tenant = @tenant
    EnvStore.set('AUTHORIZE_NET_LOGIN_ID', 'testlogin')
    EnvStore.set('AUTHORIZE_NET_TRANSACTION_KEY', 'testtxnkey')
    EnvStore.set('AUTHORIZE_NET_SANDBOX', '1')
  end

  teardown do
    EnvStore.set('AUTHORIZE_NET_LOGIN_ID', nil)
    EnvStore.set('AUTHORIZE_NET_TRANSACTION_KEY', nil)
    EnvStore.set('AUTHORIZE_NET_SANDBOX', nil)
    Current.tenant = nil
  end

  def gateway_body(response_code:, trans_id: '4000', message: 'This transaction has been approved.')
    {
      transactionResponse: {
        responseCode: response_code,
        transId: trans_id,
        authCode: response_code == '1' ? 'OK' : nil,
        messages: { code: response_code, description: message }
      }
    }.to_json
  end

  test 'charge is approved for responseCode 1' do
    stub_request(:post, 'https://apitest.authorize.net/xml/v1/request.api')
      .to_return(status: 200, body: gateway_body(response_code: '1'), headers: { 'Content-Type' => 'application/json' })

    result = AuthorizeNetClient.charge!(amount_cents: 1000, payment_nonce: 'nonce-1', ref_id: 'r1',
                                        invoice_number: 'WH-1')

    assert result.approved?
    assert_equal '4000', result.transaction_id
    assert_equal 'OK', result.auth_code
  end

  test 'charge is declined for other response codes' do
    stub_request(:post, 'https://apitest.authorize.net/xml/v1/request.api')
      .to_return(status: 200,
                 body: gateway_body(response_code: '2', message: 'This transaction has been declined.'),
                 headers: { 'Content-Type' => 'application/json' })

    result = AuthorizeNetClient.charge!(amount_cents: 1000, payment_nonce: 'bad-nonce')

    refute result.approved?
    assert_equal '2', result.response_code
    assert_includes result.message, 'declined'
  end

  test 'gateway error surfaces as a message' do
    stub_request(:post, 'https://apitest.authorize.net/xml/v1/request.api')
      .to_return(status: 200,
                 body: { messages: { resultCode: 'Error',
                                     message: [{ code: 'E00003', text: 'Invalid credentials' }] } }.to_json,
                 headers: { 'Content-Type' => 'application/json' })

    result = AuthorizeNetClient.charge!(amount_cents: 100, payment_nonce: 'nonce')

    refute result.approved?
    assert_includes result.message, 'Invalid credentials'
  end

  test 'raises when not configured' do
    EnvStore.set('AUTHORIZE_NET_LOGIN_ID', nil)
    EnvStore.set('AUTHORIZE_NET_TRANSACTION_KEY', nil)

    assert_raises(AuthorizeNetClient::Error) do
      AuthorizeNetClient.charge!(amount_cents: 100, payment_nonce: 'nonce')
    end
  end
end
