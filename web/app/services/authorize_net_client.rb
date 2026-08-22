# frozen_string_literal: true

require 'net/http'
require 'json'

# Thin client for Authorize.net's Payment API (JSON over HTTPS). Only the
# Accept.js flow is used here: the browser tokenizes card data into a payment
# nonce (opaqueData) so raw card numbers never reach the server.
#
# Credentials come from EnvStore so they can be managed from the Settings page
# (AUTHORIZE_NET_LOGIN_ID / AUTHORIZE_NET_TRANSACTION_KEY /
# AUTHORIZE_NET_CLIENT_KEY, plus AUTHORIZE_NET_SANDBOX=1 for the test gateway).
class AuthorizeNetClient
  class Error < StandardError; end

  ENDPOINTS = {
    sandbox: 'https://apitest.authorize.net/xml/v1/request.api',
    production: 'https://api.authorize.net/xml/v1/request.api'
  }.freeze

  ACCEPT_JS_URLS = {
    sandbox: 'https://jstest.authorize.net/v1/Accept.js',
    production: 'https://js.authorize.net/v1/Accept.js'
  }.freeze

  # Outcome of a transaction attempt.
  Result = Struct.new(:transaction_id, :auth_code, :response_code, :message, keyword_init: true) do
    def approved?
      response_code == '1'
    end
  end

  class << self
    def configured?
      login_id.present? && transaction_key.present?
    end

    def sandbox?
      EnvStore.fetch('AUTHORIZE_NET_SANDBOX', '0') == '1'
    end

    def accept_js_url
      ACCEPT_JS_URLS[sandbox? ? :sandbox : :production]
    end

    # Charge a tokenized (Accept.js) payment. amount_cents is the total in the
    # merchant's minor currency (USD cents).
    def charge!(amount_cents:, payment_nonce:, data_descriptor: 'COMMON.ACCEPT.INAPP.PAYMENT',
                ref_id: nil, invoice_number: nil, description: nil)
      raise Error, 'Authorize.net is not configured' unless configured?

      transaction = {
        transactionType: 'authCaptureTransaction',
        amount: format('%.2f', amount_cents.to_i / 100.0),
        payment: {
          opaqueData: {
            dataDescriptor: data_descriptor,
            dataValue: payment_nonce
          }
        }
      }
      transaction[:order] = { invoiceNumber: invoice_number, description: description } if invoice_number || description

      payload = {
        createTransactionRequest: {
          merchantAuthentication: {
            name: login_id,
            transactionKey: transaction_key
          },
          refId: ref_id,
          transactionRequest: transaction
        }
      }

      parse(post(payload))
    end

    def login_id
      EnvStore.fetch('AUTHORIZE_NET_LOGIN_ID', '')
    end

    def client_key
      EnvStore.fetch('AUTHORIZE_NET_CLIENT_KEY', '')
    end

    def transaction_key
      EnvStore.fetch('AUTHORIZE_NET_TRANSACTION_KEY', '')
    end

    private

    def post(payload)
      uri = URI(ENDPOINTS[sandbox? ? :sandbox : :production])
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 10
      http.read_timeout = 30

      request = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json', 'Accept' => 'application/json')
      request.body = JSON.generate(payload)

      response = http.request(request)
      raise Error, "Authorize.net HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    end

    def parse(body)
      doc = JSON.parse(body)
      transaction = doc['transactionResponse'] || {}
      gateway_error = doc.dig('messages', 'message', 0, 'text').to_s
      transaction_error = transaction.dig('messages', 'description').to_s
      message = transaction_error.presence || gateway_error.presence || 'Unknown Authorize.net response'

      Result.new(
        response_code: transaction['responseCode'],
        transaction_id: transaction['transId'],
        auth_code: transaction['authCode'],
        message: message
      )
    end
  end
end
