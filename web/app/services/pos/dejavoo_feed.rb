# frozen_string_literal: true

require 'openssl'
require 'base64'

module Pos
  # Receives Dejavoo FEED pushes (docs.ipospays.com/feed-integration/apidocs,
  # read 2026-11-03): every transaction and closed batch for the store's TPNs,
  # including sales run on the terminal or the online page outside Rupert.
  #
  # Authentication (the store's FEED key is PosSetting#webhook_signing_key):
  # - Basic: in iPOSpays Settings -> FEED choose Basic Authentication with API
  #   key BASIC_USER and the FEED key as the secret key. Dejavoo sends
  #   "Basic base64(user:secret)" (header "Authentication", per the docs).
  # - HMAC: HMAC-SHA512 over pipe-joined field values. Dejavoo publishes two
  #   samples that order fields differently (Java: case-sensitive key order and
  #   tpnLabel taken from tagLabel; JavaScript: case-insensitive order); a
  #   signature matching either is accepted. Neither reproduces the docs'
  #   example signature with the example key, so Basic is the setup to use.
  #
  # Kept: identifiers, amounts, batch, card brand and last four. Never kept:
  # card number, cardholder name, email, phone, card token.
  class DejavooFeed
    BASIC_USER = 'rupert'
    TEXT = /\A[[:print:]]{0,64}\z/
    DATA_FIELDS = %w[dba tpn tpnLabel deviceModel buildNumber maskedPan rrn txName transactionId externalReferenceId amount baseAmount
      totalFee trueCashDiscountFee commercialTaxAmount localTaxAmount stateTaxAmount tipAmount tipAdjAmount posRequestDate posRequestTime
      txTime hostResponseDate txDuration invoiceNumber hostResponseCode responseText approvalCode tpnBatchNumber cardLabel sourceType
      posEntryMode l2L3uploadflag commMedia destType email phoneNumber tagLabel tagValue chName additionalDetails performedBy cardInfo
      cardType transactionType cardCategory termId mid description posMode minorChannel txDate cardToken originalRRN reconId hostTxId
      consumerId subscriptionId].freeze
    NUMBERS = %w[amount baseAmount totalFee trueCashDiscountFee commercialTaxAmount localTaxAmount stateTaxAmount tipAmount tipAdjAmount].freeze

    def self.authentic?(secret:, headers:, event:)
      return false if secret.blank?

      basic = "Basic #{Base64.strict_encode64("#{BASIC_USER}:#{secret}")}"
      supplied = [headers['Authentication'], headers['Authorization']].compact.map(&:to_s)
      return true if supplied.any? { |value| ActiveSupport::SecurityUtils.secure_compare(value.strip, basic) }

      signature = event['signature'].to_s.strip.downcase
      return false unless signature.match?(/\A[0-9a-f]{128}\z/)

      hmac_candidates(event).any? { |text| ActiveSupport::SecurityUtils.secure_compare(OpenSSL::HMAC.hexdigest('SHA512', secret, text), signature) }
    end

    # Records (or, for an "U" update posting, refreshes) one event.
    def self.record!(setting, event)
      feed_id = event['id'].to_s
      raise Error, 'FEED event has no id.' unless feed_id.match?(/\A[A-Za-z0-9-]{1,64}\z/)

      row = DejavooFeedEvent.find_or_initialize_by(feed_id: feed_id)
      row.assign_attributes(pos_setting: setting, received_at: Time.current, **attributes(event))
      row.matched_kind, row.matched_id = match(setting, row) unless row.matched?
      row.save!
      row
    end

    def self.attributes(event)
      data = event['data'].is_a?(Hash) ? event['data'] : {}
      settlement = event['eventType'].to_s.casecmp?('Settlement')
      {
        request_type: text(event['requestType']).presence || 'N', event_type: settlement ? 'Settlement' : 'Transaction',
        sub_event_type: text(event['subEventType']), tpn: text(data['tpn'] || event['tpn'])[/\A[A-Za-z0-9]{1,16}\z/],
        transaction_id: text(data['transactionId'])[/\A[A-Za-z0-9-]{1,64}\z/],
        external_reference_id: text(data['externalReferenceId'])[/\A[A-Za-z0-9]{1,50}\z/],
        rrn: text(data['rrn'])[/\A[0-9]{1,20}\z/], original_rrn: text(data['originalRRN'])[/\A[0-9]{1,20}\z/],
        batch_number: text(data['tpnBatchNumber'] || event['batchNumber'])[/\A[0-9]{1,12}\z/],
        source_type: text(data['sourceType'])[/\A[A-Z]{2,8}\z/], card_label: text(data['cardLabel'])[/\A[A-Za-z ]{2,20}\z/],
        card_last_four: text(data['maskedPan'])[/(\d{4})\z/, 1], approval_code: text(data['approvalCode'])[/\A[A-Za-z0-9]{1,12}\z/],
        host_response_code: text(data['hostResponseCode'])[/\A[A-Za-z0-9]{1,4}\z/],
        amount_cents: cents(data['amount']), tip_cents: cents(data['tipAmount']),
        settlement_count: settlement && event['settlementCount'].to_s.match?(/\A\d{1,7}\z/) ? event['settlementCount'].to_i : nil,
        settlement_cents: settlement ? cents(event['settlementAmount']) : nil,
        occurred_on: text(data['txDate'] || event['settlementDate'])[/\A\d{4}-\d{2}-\d{2}/]
      }
    end

    # Which Rupert record this transaction belongs to, by the reference Rupert
    # sent: a terminal sale (SPIn ReferenceId), a terminal refund, or an online
    # payment (HPP transactionReferenceId). Nothing matched means it was run
    # outside Rupert.
    def self.match(setting, row)
      reference = row.external_reference_id
      return [nil, nil] if row.event_type != 'Transaction' || reference.blank? || reference == '0'

      if (attempt = PosPaymentAttempt.joins(:pos_checkout).where(invoice: reference, pos_checkouts: { location_id: setting.location_id }).first)
        return ['pos_payment_attempt', attempt.id]
      end
      if (reversal = PosCardReversal.joins(:pos_checkout).where(reference: reference, pos_checkouts: { location_id: setting.location_id }).first)
        return ['pos_card_reversal', reversal.id]
      end
      online = WarehousePaymentAttempt.find_by(invoice_number: reference, provider: 'dejavoo_hpp')
      online ? ['warehouse_payment_attempt', online.id] : [nil, nil]
    end

    def self.hmac_candidates(event)
      data = event['data'].is_a?(Hash) ? event['data'] : {}
      if event['eventType'].to_s.casecmp?('Settlement')
        details = Array(event['settlementTxnDetails']).grep(Hash).map do |d|
          %w[baseAmount transactionId transactionType txnAmount txnDate].map { |k| value(d[k]) }.join('|')
        end.join('|')
        fields = { 'batchNumber' => event['batchNumber'], 'createdDt' => event['createdDt'], 'eventType' => event['eventType'], 'id' => event['id'],
          'requestType' => event['requestType'], 'settlementAmount' => event['settlementAmount'], 'settlementCount' => event['settlementCount'],
          'settlementDate' => event['settlementDate'], 'settlementTxnDetails' => details, 'subEventType' => event['subEventType'],
          'tpn' => event['tpn'], 'version' => event['version'] }
        return [fields.keys.sort.map { |k| value(fields[k]) }.join('|')]
      end
      java = DATA_FIELDS.sort.map { |field| data_value(data, field, tpn_label: data['tagLabel']) }
      js = DATA_FIELDS.sort_by(&:downcase).map { |field| data_value(data, field, tpn_label: data['tpnLabel']) }
      [java, js].map { |values| [value(event['createdDt']), *values, *%w[eventType id requestType subEventType version].map { |k| value(event[k]) }].join('|') }
    end

    def self.data_value(data, field, tpn_label:)
      raw = case field
            when 'tpnLabel' then tpn_label
            when 'l2L3uploadflag' then data['L2L3uploadflag'] || data['L2l3UploadFlag'] || data['l2L3uploadflag']
            when 'termId' then data['TermId'] || data['termId']
            when 'mid' then data['Mid'] || data['mid']
            else data[field]
            end
      NUMBERS.include?(field) ? number(raw) : value(raw)
    end

    # Java Double.toString / the JavaScript sample's formatNumber for amounts.
    def self.number(raw)
      amount = raw.nil? ? 0.0 : Float(raw.to_s)
      (amount % 1).zero? ? format('%.1f', amount) : amount.to_s
    rescue ArgumentError
      raw.to_s
    end

    def self.value(raw) = raw.nil? ? '' : raw.to_s
    def self.text(raw) = raw.to_s.strip.then { |s| s.match?(TEXT) ? s : '' }

    def self.cents(raw)
      amount = BigDecimal(raw.to_s)
      (amount * 100).frac.zero? && amount.abs < 10_000_000 ? (amount * 100).to_i : nil
    rescue ArgumentError, TypeError
      nil
    end
  end
end
