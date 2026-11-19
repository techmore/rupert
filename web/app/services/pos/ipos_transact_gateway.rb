# frozen_string_literal: true

require 'net/http'
require 'openssl'
require 'json'
require 'securerandom'

module Pos
  # Dejavoo iPOS Transact client for ONLINE card payments. SANDBOX ONLY.
  #
  # The shopper types the card into Dejavoo's Freedom to Design (FTD) fields.
  # FTD turns it into a single-use paymentTokenId in the browser; Rupert only
  # receives that token and charges it here. Rupert never sees or stores a card
  # number, expiry or CVV, and never uses Dejavoo's Clear Card API (which would
  # send raw card data through Rupert and widen PCI scope).
  #
  # Contract: iPOS Transact "Sale with paymentTokenId", read 2026-11-03 at
  # docs.ipospays.com/ipos-transact/sale/sale-paymenttoken/post. One endpoint,
  # `token` header, JSON body with merchantAuthentication (TPN + unique
  # reference) and transactionRequest (type 1 = sale, amount in cents as a
  # string). Declines come back as HTTP 200 with responseCode "400".
  #
  # Not built yet, because Dejavoo's public docs do not give them: void,
  # refund and a status lookup. Without a status lookup a lost response cannot
  # be resolved automatically, so it is reported as "unknown" and must be
  # checked in the iPOSpays portal. The paymentTokenId is single use, so Rupert
  # never resends a sale.
  class IposTransactGateway
    HOSTS = { 'sandbox' => 'https://payment.ipospays.tech/api/v3/iposTransact' }.freeze
    FTD_SCRIPT_HOSTS = { 'sandbox' => 'https://payment.ipospays.tech' }.freeze
    MAX_BYTES = 64 * 1024
    READ_TIMEOUT = 60
    TPN = /\A\d{12}\z/
    TOKEN = /\A[A-Za-z0-9._~+\/=-]{16,2048}\z/
    REFERENCE = /\A[A-Za-z0-9]{1,42}\z/
    PAYMENT_TOKEN = /\A[0-9a-fA-F-]{16,64}\z/
    SALE = 1

    Response = Data.define(:outcome, :reference_id, :transaction_id, :amount_cents, :total_cents, :approval_code,
      :processor_code, :rrn, :batch_number) do
      def approved? = outcome == 'approved'
      def declined? = outcome == 'declined'
    end

    def self.reference = "RO#{SecureRandom.hex(16)}"

    def self.url(environment) = HOSTS.fetch(environment) { raise Error, 'Dejavoo online payments are sandbox only in Rupert.' }

    def initialize(tpn:, token:, environment: 'sandbox')
      raise Error, 'Dejavoo online payments are sandbox only in Rupert.' unless HOSTS.key?(environment)
      raise Error, 'Enter the 12-digit CloudPOS TPN and the iPOS Transact token.' unless tpn.to_s.match?(TPN) && token.to_s.match?(TOKEN)

      @environment = environment
      @tpn = tpn.to_s
      @token = token.to_s
    end

    # Charges a single-use FTD paymentTokenId. Never retried.
    def sale(reference:, payment_token_id:, amount_cents:)
      raise Error, 'Invalid Dejavoo transaction reference.' unless reference.to_s.match?(REFERENCE)
      raise Error, 'Invalid card token from the payment form.' unless payment_token_id.to_s.match?(PAYMENT_TOKEN)
      raise Error, 'Dejavoo amount is out of range.' unless amount_cents.is_a?(Integer) && amount_cents.between?(1, 99_999_999)

      body = {
        merchantAuthentication: { merchantId: @tpn, transactionReferenceId: reference.to_s },
        transactionRequest: { transactionType: SALE, amount: amount_cents.to_s, paymentTokenId: payment_token_id.to_s,
                              applySteamSettingTipFeeTax: false },
        preferences: { eReceipt: false, requestCardToken: false }
      }
      parse(post(body), reference.to_s)
    end

    private

    def parse(doc, reference)
      data = doc['iposhpresponse']
      raise Error, 'Dejavoo outcome could not be verified. Check the iPOSpays portal before charging again.' unless data.is_a?(Hash)

      echoed = data['transactionReferenceId'].to_s
      outcome = case data['responseCode'].to_s
                when '200' then echoed == reference ? 'approved' : 'unknown'
                when '400' then 'declined'
                else 'unknown'
                end
      Response.new(outcome: outcome, reference_id: echoed.match?(REFERENCE) ? echoed : nil,
        transaction_id: data['transactionId'].to_s[/\A[A-Za-z0-9-]{1,32}\z/],
        amount_cents: cents(data['amount']), total_cents: cents(data['totalAmount']),
        approval_code: data['responseApprovalCode'].to_s[/\A[A-Za-z0-9]{1,6}\z/],
        processor_code: data['errResponseCode'].to_s[/\A[A-Za-z0-9]{1,4}\z/],
        rrn: data['rrn'].to_s[/\A\d{1,12}\z/], batch_number: data['batchNumber'].to_s[/\A\d{1,6}\z/])
    end

    # The docs say request amounts are cents but responses are "xxxxxx.xx".
    # Accept only the dotted dollar form; anything else is left unknown.
    def cents(value)
      text = value.to_s
      return nil unless text.match?(/\A\d{1,8}\.\d{2}\z/)

      (BigDecimal(text) * 100).to_i
    end

    def post(body)
      uri = URI(self.class.url(@environment))
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.min_version = OpenSSL::SSL::TLS1_2_VERSION
      http.open_timeout = 5
      http.write_timeout = 10
      http.read_timeout = READ_TIMEOUT
      http.max_retries = 0
      request = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json', 'Accept' => 'application/json',
        'Accept-Encoding' => 'identity', 'token' => @token)
      request.body = JSON.generate(body)
      raw = +''
      status = nil
      http.start do |session|
        session.request(request) do |response|
          status = response.code
          response.read_body do |chunk|
            raw << chunk
            raise Error, 'Dejavoo response exceeded its limit.' if raw.bytesize > MAX_BYTES
          end
        end
      end
      raise Error, 'Dejavoo rejected the request. Check the TPN, token and amount.' if status == '400'
      raise Error, 'Dejavoo outcome could not be verified. Check the iPOSpays portal before charging again.' unless status == '200'

      doc = JSON.parse(raw, max_nesting: 10)
      raise Error, 'Dejavoo outcome could not be verified. Check the iPOSpays portal before charging again.' unless doc.is_a?(Hash)

      doc
    rescue JSON::ParserError, EncodingError, Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError
      raise Error, 'Dejavoo outcome could not be verified. Check the iPOSpays portal before charging again.'
    end
  end
end
