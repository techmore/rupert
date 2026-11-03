# frozen_string_literal: true

# Stubs Dejavoo's SPIn REST cloud (sandbox host) for one test. Response shapes
# follow the SPIn REST docs read 2026-11-02 (app.theneo.io/dejavoo/spin):
# GeneralResponse with a four-digit StatusCode, Amounts, CardData, and so on.
# Every response also carries card fields Rupert must drop (First4, BIN, name,
# expiry, receipts, EMV data, tokens), so tests can prove they are never kept.
module DejavooSpinFixture
  TPN = 'SBXTPN0001'
  AUTH_KEY = 'SbxAuth001'
  HOST = 'https://test.spinpos.net/spin'

  def dejavoo_credentials = { tpn: TPN, auth_key: AUTH_KEY }.to_json

  def prepare_dejavoo_fixture
    @spin_requests = []
    @spin_sale_mode = :approved
    @spin_status_mode = :approved
    @spin_void_mode = :approved
    @spin_total = '11.66'
    @spin_fee = '0'
    @spin_tip = '1.01'
    @spin_transactions = {}
    stub_request(:post, %r{\A#{Regexp.escape(HOST)}/v2/}).to_return do |request|
      path = request.uri.path.delete_prefix('/spin/')
      body = JSON.parse(request.body)
      assert_equal TPN, body.fetch('Tpn')
      assert_equal AUTH_KEY, body.fetch('Authkey')
      assert_nil request.headers['Authorization']
      @spin_requests << [path, body]
      spin_response(path, body)
    end
  end

  def spin_sales = @spin_requests.count { |path, _| path == 'v2/Payment/Sale' }

  def spin_paths = @spin_requests.map(&:first)

  def spin_response(path, body)
    case path
    when 'v2/Payment/Sale'
      @spin_during_sale&.call
      raise Net::ReadTimeout if @spin_sale_mode == :timeout

      code = { approved: '0000', partial: '0001', declined: '1015', canceled: '1012', offline: '2001', timed_out: '2007', bad_key: '1009' }.fetch(@spin_sale_mode)
      @spin_transactions[body['ReferenceId']] = { code: code, voided: false, total: @spin_sale_mode == :partial ? '5.00' : @spin_total } if %w[0000 0001].include?(code)
      spin_json(code, body['ReferenceId'], total: @spin_sale_mode == :partial ? '5.00' : @spin_total)
    when 'v2/Payment/Status'
      raise Net::ReadTimeout if @spin_status_mode == :timeout
      return spin_json('1016', nil) if @spin_status_mode == :debit && body['PaymentType'] == 'Credit'

      row = @spin_transactions[body['ReferenceId']]
      if @spin_status_mode == :not_found || row.nil?
        spin_json('2009', nil, status: 400)
      else
        spin_json(row[:code], body['ReferenceId'], total: row[:total], voided: row[:voided], payment_type: body['PaymentType'])
      end
    when 'v2/Payment/Void'
      raise Net::ReadTimeout if @spin_void_mode == :timeout
      return spin_json('1015', body['ReferenceId'], status: 400) if @spin_void_mode == :declined

      @spin_transactions.fetch(body['ReferenceId'])[:voided] = true
      spin_json('0000', body['ReferenceId'], total: format('%.2f', body['Amount']), voided: true, type: 'Void')
    when 'v2/Payment/AbortTransaction'
      { status: 200, headers: { 'Content-Type' => 'application/json' },
        body: { GeneralResponse: { ResultCode: '0', StatusCode: '0000', Message: 'Success', DetailedMessage: '' } }.to_json }
    when 'v2/Payment/Settle'
      { status: 200, body: { SettleDetails: [{ MerchantNumber: 1, BatchNumber: 42, HostStatus: 'Ok',
        TransactionsReports: { TransactionsCount: 3, SaleAmount: 30.5, ReturnAmount: 5, VoidAmount: 0, TotalAmount: 25.5 } }],
        GeneralResponse: { ResultCode: '0', StatusCode: '0000', Message: 'Success', DetailedMessage: '' } }.to_json }
    else
      flunk "Unexpected SPIn path #{path}"
    end
  end

  def spin_json(code, reference, total: @spin_total, voided: false, type: 'Sale', payment_type: 'Credit', status: nil)
    status ||= code.start_with?('0') ? 200 : 400
    body = { GeneralResponse: { HostResponseCode: '00', HostResponseMessage: 'APPROVAL 4111111111111111', ResultCode: code.start_with?('0') ? '0' : '1',
      StatusCode: code, Message: "Card 4111111111111111 #{code}", DetailedMessage: 'detail' } }
    if %w[0000 0001].include?(code)
      body.merge!(PaymentType: payment_type, TransactionType: type, ReferenceId: reference, InvoiceNumber: 'inv', SerialNumber: 'SN1',
        BatchNumber: '7', TransactionNumber: '12', AuthCode: 'A1B2C3', PNReferenceId: '987654321', Voided: voided, RRN: '1234',
        Token: 'card-token-secret', IPosToken: 'ipos-token-secret', Signature: 'iVBORw0KGgo=',
        Amounts: { TotalAmount: BigDecimal(total).to_f, Amount: BigDecimal(total).to_f, TipAmount: BigDecimal(@spin_tip).to_f, FeeAmount: BigDecimal(@spin_fee).to_f, TaxAmount: 0.6 },
        CardData: { CardType: 'Visa', EntryType: 'Contactless', Last4: '1111', First4: '4111', BIN: '411111', ExpirationDate: '1229', Name: 'PAT CARDHOLDER' },
        EMVData: { ApplicationName: 'VISA CREDIT', AID: 'A0000000031010', TVR: '0000000000' },
        Receipts: { Customer: 'CUSTOMER COPY 4111111111111111', Merchant: 'MERCHANT COPY' })
    end
    { status: status, headers: { 'Content-Type' => 'application/json' }, body: body.to_json }
  end
end
