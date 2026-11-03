# frozen_string_literal: true

require 'net/http'
require 'openssl'
require 'json'

# Dejavoo iPOSpays Hosted Payment Page (HPP) for online checkout.
#
# The shopper is redirected to Dejavoo's own payment page and types the card
# there, so no card field is ever on a Rupert page (PCI SAQ A scope). Rupert
# never trusts what comes back with the browser: it confirms every payment
# server-to-server with queryPaymentStatus for its own reference and amount.
#
# Contract: docs.ipospays.com/hosted-payment-page/api-docs (generateAuthToken,
# notifyByReturn, queryPaymentStatus, cancelTransaction), read 2026-11-03.
# Settings (encrypted, Settings page):
#   DEJAVOO_HPP_TPN          12-digit CloudPOS TPN
#   DEJAVOO_HPP_API_KEY      iPOSpays API key   } create the payment page
#   DEJAVOO_HPP_SECRET_KEY   iPOSpays secret key }
#   DEJAVOO_HPP_ECOM_TOKEN   Merchant Keys/Ecom Token (status lookups)
#   DEJAVOO_HPP_ENVIRONMENT  sandbox (default) or production
#   DEJAVOO_HPP_PRODUCTION_SIGNOFF  who approved live payments and when; required for production
# Refunds of HPP payments are not available yet: Dejavoo's public docs give no
# void/refund call for them (cancelTransaction only cancels an unpaid link).
module DejavooHostedPage
  class Error < StandardError; end

  HOSTS = {
    'sandbox' => { auth: 'https://auth.ipospays.tech/v1/authenticate-token',
                   create: 'https://payment.ipospays.tech/api/v3/external-payment-transaction',
                   status: 'https://api.ipospays.tech/v1/queryPaymentStatus',
                   pay: 'https://payment.ipospays.tech' },
    'production' => { auth: 'https://auth.ipospays.com/v1/authenticate-token',
                      create: 'https://payment.ipospays.com/api/v3/external-payment-transaction',
                      status: 'https://api.ipospays.com/v1/queryPaymentStatus',
                      pay: 'https://payment.ipospays.com' }
  }.freeze
  PAY_ORIGINS = HOSTS.values.map { |hosts| hosts[:pay] }.freeze
  TPN = /\A\d{12}\z/
  REFERENCE = /\A[A-Za-z0-9]{1,42}\z/
  KEY = /\A[[:graph:]]{8,512}\z/
  MAX_BYTES = 64 * 1024
  TOKEN_CACHE = 'dejavoo_hpp/auth_token'

  Status = Data.define(:outcome, :reference_id, :transaction_id, :total_cents, :card_brand, :card_last_four, :approval_code) do
    def approved? = outcome == 'approved'
  end

  module_function

  def environment = EnvStore.fetch('DEJAVOO_HPP_ENVIRONMENT', 'sandbox').to_s.strip.presence || 'sandbox'
  def sandbox? = environment == 'sandbox'
  def tpn = EnvStore.fetch('DEJAVOO_HPP_TPN', '').to_s.strip

  # Live payments need the owner's recorded sign-off, as for the terminal.
  def configured?
    return false unless HOSTS.key?(environment) && tpn.match?(TPN)
    return false unless %w[DEJAVOO_HPP_API_KEY DEJAVOO_HPP_SECRET_KEY DEJAVOO_HPP_ECOM_TOKEN].all? { |key| EnvStore.fetch(key, '').to_s.strip.match?(KEY) }

    sandbox? || EnvStore.fetch('DEJAVOO_HPP_PRODUCTION_SIGNOFF', '').to_s.squish.length >= 10
  end

  def fingerprint = Digest::SHA256.hexdigest(['dejavoo_hpp', environment, tpn].to_json)

  # Returns the Dejavoo payment page URL for this reference and amount. Tax,
  # fees and tips are off: the shopper pays exactly Rupert's total.
  def create_page(reference:, amount_cents:, return_url:, cancel_url:, merchant_name:)
    raise Error, 'Dejavoo online payments are not set up.' unless configured?
    raise Error, 'Invalid payment reference.' unless reference.to_s.match?(REFERENCE)
    raise Error, 'Amount is out of range.' unless amount_cents.is_a?(Integer) && amount_cents.between?(1, 99_999_999)

    body = {
      merchantAuthentication: { merchantId: tpn, transactionReferenceId: reference },
      transactionRequest: { transactionType: 1, amount: amount_cents.to_s, calculateFee: false, tipsInputPrompt: false, calculateTax: false, expiry: 1 },
      notificationOption: { notifyByRedirect: true, returnUrl: return_url, failureUrl: return_url, cancelUrl: cancel_url },
      preferences: { integrationType: 1, avsVerification: false, eReceipt: false, eReceiptInputPrompt: false, requestCardToken: false,
                     sendPaymentLink: false, shortenURL: false, integrationVersion: 'v2' },
      personalization: { merchantName: merchant_name.to_s.gsub(/[^A-Za-z0-9 .&'-]/, '')[0, 40] }
    }
    doc = request(:post, hosts[:create], { 'token' => auth_token, 'Content-Type' => 'application/json' }, JSON.generate(body))
    url = doc['information'].to_s
    raise Error, 'Dejavoo did not return a payment page.' unless url.start_with?("#{hosts[:pay]}/") && url.length <= 2048 && !url.match?(/\s/)

    url
  end

  # Server-to-server truth for one reference. Never trusts the browser.
  def status(reference)
    raise Error, 'Invalid payment reference.' unless reference.to_s.match?(REFERENCE)

    query = URI.encode_www_form(tpn: tpn, transactionReferenceId: reference)
    doc = request(:get, "#{hosts[:status]}?#{query}", { 'Authorization' => EnvStore.fetch('DEJAVOO_HPP_ECOM_TOKEN', '').to_s.strip }, nil)
    parse_status(doc, reference.to_s)
  end

  def parse_status(doc, reference)
    data = doc['iposHPResponse']
    return Status.new(outcome: 'not_found', reference_id: nil, transaction_id: nil, total_cents: nil, card_brand: nil, card_last_four: nil, approval_code: nil) unless data.is_a?(Hash)

    echoed = data['transactionReferenceId'].to_s
    message = data['responseMessage'].to_s.downcase
    outcome = if echoed != reference then 'unknown'
    elsif data['responseCode'].to_s == '200' && message.start_with?('success') then 'approved'
    elsif message.include?('cancel') then 'cancelled'
    elsif message.include?('declin') || message.include?('reject') then 'declined'
    else 'unknown'
    end
    Status.new(outcome: outcome, reference_id: echoed.match?(REFERENCE) ? echoed : nil,
      transaction_id: data['transactionId'].to_s[/\A[A-Za-z0-9-]{1,64}\z/], total_cents: cents(data['totalAmount']),
      card_brand: data['cardType'].to_s[/\A[A-Za-z ]{2,20}\z/], card_last_four: data['cardLast4Digit'].to_s[/\A\d{4}\z/],
      approval_code: data['responseApprovalCode'].to_s[/\A[A-Za-z0-9]{1,12}\z/])
  end

  # Responses give dollars ("12.50"). Anything else is left unknown, so an
  # approval is only accepted when the amount can be checked exactly.
  def cents(value)
    text = value.to_s.strip
    text.match?(/\A\d{1,8}\.\d{2}\z/) ? (BigDecimal(text) * 100).to_i : nil
  end

  def hosts = HOSTS.fetch(environment)

  def auth_token
    Rails.cache.fetch("#{TOKEN_CACHE}/#{fingerprint}", expires_in: 50.minutes) do
      doc = request(:post, hosts[:auth], { 'apiKey' => EnvStore.fetch('DEJAVOO_HPP_API_KEY', '').to_s.strip,
        'secretKey' => EnvStore.fetch('DEJAVOO_HPP_SECRET_KEY', '').to_s.strip, 'TokenExpiryMinutes' => '60' }, nil)
      token = doc['token'].to_s
      raise Error, 'Dejavoo refused the API key or secret key.' unless doc['responseCode'].to_s == '00' && token.match?(/\A[A-Za-z0-9._-]{20,4096}\z/)

      token
    end
  end

  def request(method, url, headers, body)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port, nil)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    http.min_version = OpenSSL::SSL::TLS1_2_VERSION
    http.open_timeout = 5
    http.write_timeout = 10
    http.read_timeout = 20
    http.max_retries = 0
    req = (method == :get ? Net::HTTP::Get : Net::HTTP::Post).new(uri.request_uri, headers.merge('Accept' => 'application/json', 'Accept-Encoding' => 'identity'))
    req.body = body if body
    raw = +''
    code = nil
    http.start do |session|
      session.request(req) do |response|
        code = response.code
        response.read_body do |chunk|
          raw << chunk
          raise Error, 'Dejavoo response exceeded its limit.' if raw.bytesize > MAX_BYTES
        end
      end
    end
    raise Error, 'Dejavoo refused the request.' unless %w[200 201].include?(code)

    doc = JSON.parse(raw, max_nesting: 10)
    raise Error, 'Dejavoo response could not be read.' unless doc.is_a?(Hash)

    doc
  rescue JSON::ParserError, EncodingError, Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError
    raise Error, 'Dejavoo could not be reached. No payment was confirmed.'
  end
end
