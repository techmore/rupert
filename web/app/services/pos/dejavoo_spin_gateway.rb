# frozen_string_literal: true

require 'net/http'
require 'openssl'
require 'json'
require 'securerandom'

module Pos
  # Dejavoo SPIn (semi-integrated) cloud client. Production only after the
  # owner records sign-off on the POS setting.
  #
  # Rupert sends a request to Dejavoo's SPIn cloud, which forwards it to the
  # store's Dejavoo terminal. The customer taps, dips or swipes on the terminal;
  # card data stays on the terminal and Rupert only receives the result
  # (approval, last four, brand, auth code). That keeps card numbers out of
  # Rupert entirely.
  #
  # Contract: SPIn REST API, read 2026-11-02 at app.theneo.io/dejavoo/spin
  # (methods under /v2/Payment and /v2/Common; credentials Tpn and Authkey in
  # the JSON body; GeneralResponse.StatusCode four-digit codes). The sandbox
  # host is the one Dejavoo's docs give for SPIn REST. Production needs a live
  # TPN from the processor and the owner's recorded sign-off, as for NMI.
  #
  # Never stored or returned: the raw response, receipts, signatures, card
  # tokens, BIN/first four, cardholder name, expiry, EMV data or messages from
  # the terminal. Only the fields in Response are kept.
  class DejavooSpinGateway
    # Production host from the SPIn REST docs. "Check gateway" proves it with a
    # status lookup for a reference that cannot exist, before any card runs.
    HOSTS = { 'sandbox' => 'https://test.spinpos.net/spin', 'production' => 'https://api.spinpos.net' }.freeze
    MAX_BYTES = 256 * 1024
    # Seconds the SPIn proxy waits for the terminal (documented default 120).
    TERMINAL_TIMEOUT = 90
    SETTLE_TIMEOUT = 300
    REFERENCE = /\A[A-Za-z0-9]{1,50}\z/
    TPN = /\A[A-Za-z0-9]{10,12}\z/
    AUTH_KEY = /\A[A-Za-z0-9]{8,64}\z/
    PAYMENT_TYPES = %w[Credit Debit].freeze

    # What a SPIn StatusCode means for money. Only "approved" and "partial"
    # mean a card was charged. "rejected" and "unavailable" are refusals before
    # the terminal ran a card (bad setup, terminal offline or busy with another
    # request). Anything else, including timeouts, is "unknown": check Status
    # before doing anything that could charge twice.
    OUTCOMES = {
      'approved' => %w[0000],
      'partial' => %w[0001],
      'declined' => %w[1015 1012],
      'not_found' => %w[1001 2009],
      'rejected' => %w[1002 1003 1004 1007 1008 1009 1010 1013 1016 1017 1019 1020 2002 2003 2004 2005 2006 2101 2102 2201],
      'unavailable' => %w[1000 1005 2001 2008 2011]
    }.flat_map { |outcome, codes| codes.map { |code| [code, outcome] } }.to_h.freeze

    CARD_BRANDS = { 'Visa' => 'Visa', 'Mastercard' => 'Mastercard', 'Amex' => 'Amex', 'Discover' => 'Discover', 'JCB' => 'JCB' }.freeze
    ENTRY_TYPES = %w[Chip Swipe ChipContactless Contactless Manual].freeze

    Response = Data.define(:status_code, :outcome, :reference_id, :payment_type, :transaction_type, :total_cents, :tip_cents,
      :fee_cents, :auth_code, :processor_reference, :batch_number, :card_brand, :card_last_four, :entry_type, :voided, :retry_after) do
      def approved? = outcome == 'approved'
      def charged? = %w[approved partial].include?(outcome)
      def no_charge? = %w[declined rejected unavailable].include?(outcome)
    end

    attr_reader :setting, :version, :terminal

    def self.url(environment, path) = "#{HOSTS.fetch(environment) { raise Error, 'Unknown Dejavoo environment.' }}/#{path}"

    def self.reference = "RD#{SecureRandom.hex(12)}"

    # terminal: an extra PosTerminal of this store, or nil for the main TPN.
    def initialize(setting, terminal: nil)
      raise Error, 'Gateway belongs to another workspace.' unless setting.persisted? && setting.tenant_id == Current.tenant_id
      raise Error, 'This store is not set up for Dejavoo terminals.' unless setting.gateway_provider == 'dejavoo_spin'
      raise Error, 'Dejavoo production needs owner sign-off in checkout setup first.' unless HOSTS.key?(setting.environment) && setting.dejavoo_ready_environment?

      @setting = setting
      @environment = setting.environment
      @version = setting.lock_version
      if terminal && !(terminal.tenant_id == setting.tenant_id && terminal.location_id == setting.location_id)
        raise Error, 'That terminal belongs to another store.'
      end

      @terminal = terminal
      @credentials = terminal ? terminal.credentials : setting.credentials
      raise Error, 'Save the Dejavoo terminal TPN and auth key first.' unless @credentials['tpn'].to_s.match?(TPN) && @credentials['auth_key'].to_s.match?(AUTH_KEY)

      @fingerprint = terminal ? terminal.payment_fingerprint(setting) : setting.payment_fingerprint
    end

    def sandbox? = @environment == 'sandbox'

    def assert_checkout!(checkout)
      unless checkout.tenant_id == Current.tenant_id && checkout.location_id == @setting.location_id &&
          checkout.gateway_provider == 'dejavoo_spin' && checkout.environment == @environment &&
          checkout.gateway_fingerprint == @fingerprint
        raise Error, 'Dejavoo terminal setup changed. Review the original payment setup.'
      end
    end

    # Checks the TPN and auth key and that the terminal is reachable, without
    # running a card: asks for the status of a reference that cannot exist.
    # Keeps the auth key in the request body (the TerminalStatus GET would put
    # it in a URL).
    def verify!
      result = status(self.class.reference)
      return true if result.outcome == 'not_found'
      raise Error, 'The Dejavoo terminal is not connected to SPIn. Turn it on and check its network.' if result.outcome == 'unavailable'

      raise Error, 'Dejavoo refused the TPN or auth key. Check them in the iPOSpays portal.'
    end

    def sale(reference:, amount_cents:, tip_cents: 0, payment_type: 'Credit', invoice: nil)
      check_money!(amount_cents, tip_cents)
      body = payment_fields(reference, payment_type).merge(Amount: dollars(amount_cents), PrintReceipt: 'No', GetReceipt: 'No',
        CaptureSignature: false, GetExtendedData: true, SPInProxyTimeout: TERMINAL_TIMEOUT)
      body[:TipAmount] = dollars(tip_cents) if tip_cents.positive?
      body[:InvoiceNumber] = invoice if invoice
      call('v2/Payment/Sale', body, reference)
    end

    # The documented recovery after a timeout or lost response.
    def status(reference, payment_type: 'Credit')
      call('v2/Payment/Status', payment_fields(reference, payment_type).merge(GetExtendedData: true, SPInProxyTimeout: TERMINAL_TIMEOUT), reference)
    end

    # Reverses an unsettled sale. SPIn needs the original ReferenceId and amount.
    def void(reference:, amount_cents:, payment_type: 'Credit')
      check_money!(amount_cents, 0)
      call('v2/Payment/Void', payment_fields(reference, payment_type).merge(Amount: dollars(amount_cents), PrintReceipt: 'No', GetReceipt: 'No',
        GetExtendedData: true, SPInProxyTimeout: TERMINAL_TIMEOUT), reference)
    end

    # A SPIn return is independent of the sale and needs its own new reference.
    # The customer presents the card on the terminal again.
    def refund(reference:, amount_cents:, payment_type: 'Credit')
      check_money!(amount_cents, 0)
      call('v2/Payment/Return', payment_fields(reference, payment_type).merge(Amount: dollars(amount_cents), PrintReceipt: 'No', GetReceipt: 'No',
        GetExtendedData: true, SPInProxyTimeout: TERMINAL_TIMEOUT), reference)
    end

    def tip_adjust(reference:, amount_cents:, tip_cents:, payment_type: 'Credit')
      check_money!(amount_cents, tip_cents)
      call('v2/Payment/TipAdjust', payment_fields(reference, payment_type).merge(Amount: dollars(amount_cents), TipAmount: dollars(tip_cents),
        GetExtendedData: true, SPInProxyTimeout: TERMINAL_TIMEOUT), reference)
    end

    # Cancels the request the terminal is waiting on (for example the customer
    # walked away). Its result is only a GeneralResponse; check Status after.
    def abort(reference)
      call('v2/Payment/AbortTransaction', credentials.merge(ReferenceId: checked_reference(reference)), nil)
    end

    # Closes the terminal's open batch. Returns batch totals in cents.
    def settle
      doc = post('v2/Payment/Settle', credentials.merge(SettlementType: 'Close', GetReceipt: false, SPInProxyTimeout: SETTLE_TIMEOUT), SETTLE_TIMEOUT + 30)
      code = status_code(doc)
      details = doc['SettleDetails']
      raise Error, 'Dejavoo did not close the batch.' unless code == '0000' && details.is_a?(Array) && details.all?(Hash)

      details.map do |row|
        report = row['TransactionsReports'].is_a?(Hash) ? row['TransactionsReports'] : {}
        { batch_number: row['BatchNumber'].to_s[/\A\d{1,12}\z/], count: report['TransactionsCount'].to_s[/\A\d{1,6}\z/]&.to_i,
          sale_cents: cents(report['SaleAmount']), return_cents: cents(report['ReturnAmount']), void_cents: cents(report['VoidAmount']),
          total_cents: cents(report['TotalAmount']) }
      end
    end

    def dollars(cents) = (BigDecimal(cents.to_s) / 100).round(2).to_f

    private

    def credentials = { Tpn: @credentials.fetch('tpn'), Authkey: @credentials.fetch('auth_key') }

    def payment_fields(reference, payment_type)
      raise Error, 'Unsupported Dejavoo payment type.' unless PAYMENT_TYPES.include?(payment_type)

      credentials.merge(PaymentType: payment_type, ReferenceId: checked_reference(reference))
    end

    def checked_reference(reference)
      raise Error, 'Invalid Dejavoo transaction reference.' unless reference.to_s.match?(REFERENCE)

      reference.to_s
    end

    def check_money!(amount_cents, tip_cents)
      unless amount_cents.is_a?(Integer) && amount_cents.between?(1, 99_999_99) && tip_cents.is_a?(Integer) && tip_cents.between?(0, amount_cents)
        raise Error, 'Dejavoo amount is out of range.'
      end
    end

    def call(path, body, reference)
      doc = post(path, body, TERMINAL_TIMEOUT + 20)
      parse(doc, reference)
    end

    def parse(doc, reference)
      code = status_code(doc)
      outcome = OUTCOMES.fetch(code, 'unknown')
      echoed = doc['ReferenceId']
      # A charge result must name our reference. Anything else is not ours to trust.
      if %w[approved partial].include?(outcome) && reference && echoed.to_s != reference
        outcome = 'unknown'
      end
      amounts = doc['Amounts'].is_a?(Hash) ? doc['Amounts'] : {}
      card = doc['CardData'].is_a?(Hash) ? doc['CardData'] : {}
      payment_type = doc['PaymentType'].to_s
      delay = doc.dig('GeneralResponse', 'DelayBeforeNextRequest')
      Response.new(status_code: code, outcome: outcome, reference_id: echoed.to_s.match?(REFERENCE) ? echoed.to_s : nil,
        payment_type: PAYMENT_TYPES.include?(payment_type) ? payment_type : nil,
        transaction_type: doc['TransactionType'].to_s[/\A[A-Za-z]{1,20}\z/],
        total_cents: cents(amounts['TotalAmount']), tip_cents: cents(amounts['TipAmount']), fee_cents: cents(amounts['FeeAmount']),
        auth_code: doc['AuthCode'].to_s[/\A[A-Za-z0-9]{1,12}\z/], processor_reference: doc['PNReferenceId'].to_s[/\A[A-Za-z0-9-]{1,40}\z/],
        batch_number: doc['BatchNumber'].to_s[/\A\d{1,12}\z/], card_brand: CARD_BRANDS[card['CardType'].to_s],
        card_last_four: card['Last4'].to_s[/\A\d{4}\z/], entry_type: ENTRY_TYPES.include?(card['EntryType'].to_s) ? card['EntryType'].to_s : nil,
        voided: doc['Voided'] == true, retry_after: delay.is_a?(Numeric) && delay.between?(0, 600) ? delay.to_f : nil)
    end

    def status_code(doc)
      general = doc['GeneralResponse']
      raise Error, 'Dejavoo response could not be verified. Check payment status before retrying.' unless general.is_a?(Hash)

      code = general['StatusCode'].to_s
      raise Error, 'Dejavoo response could not be verified. Check payment status before retrying.' unless code.match?(/\A\d{4}\z/)

      code
    end

    # Decimal dollars (number or string) to integer cents, or nil when absent or
    # not a clean amount.
    def cents(value)
      return nil if value.nil?

      amount = BigDecimal(value.to_s)
      return nil unless amount >= 0 && (amount * 100).frac.zero?

      (amount * 100).to_i
    rescue ArgumentError, TypeError
      nil
    end

    def post(path, body, read_timeout)
      uri = URI(self.class.url(@environment, path))
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 5
      http.write_timeout = 10
      http.read_timeout = read_timeout
      http.max_retries = 0
      request = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json', 'Accept' => 'application/json', 'Accept-Encoding' => 'identity')
      request.body = JSON.generate(body)
      raw = +''
      http.start do |session|
        session.request(request) do |response|
          # SPIn answers refusals with HTTP 400 and a GeneralResponse body.
          raise Error, 'Dejavoo outcome could not be verified. Check payment status before retrying.' unless %w[200 400].include?(response.code)

          response.read_body do |chunk|
            raw << chunk
            raise Error, 'Dejavoo response exceeded its limit.' if raw.bytesize > MAX_BYTES
          end
        end
      end
      doc = JSON.parse(raw.b.delete_prefix("\xEF\xBB\xBF".b).force_encoding(Encoding::UTF_8), max_nesting: 20, decimal_class: BigDecimal)
      raise Error, 'Dejavoo response could not be verified. Check payment status before retrying.' unless doc.is_a?(Hash)

      doc
    rescue JSON::ParserError, EncodingError, Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError
      raise Error, 'Dejavoo outcome could not be verified. Check payment status before retrying.'
    end
  end
end
