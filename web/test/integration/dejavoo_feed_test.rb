# frozen_string_literal: true

require 'test_helper'
require 'base64'
require_relative '../support/dejavoo_spin_fixture'

# Dejavoo FEED pushes reach Rupert's POS webhook, authenticated, stripped of
# card and personal data, and matched to the Rupert record they belong to.
class DejavooFeedTest < ActionDispatch::IntegrationTest
  include DejavooSpinFixture

  FEED_KEY = 'made-up-feed-key-for-tests-0001'

  setup do
    Current.tenant = tenants(:default_tenant)
    @location = Location.create!(source: 'ctrax', externalId: 'dejavoo-feed/1', name: 'Feed store')
    @setting = PosSetting.create!(location: @location, gateway_provider: 'dejavoo_spin', environment: 'sandbox', credentials_json: dejavoo_credentials,
      webhook_signing_key: FEED_KEY)
  end
  teardown { Current.reset }

  def sale_event(reference: 'RDexternal0001', id: '6ea412fc-7181-4eb6-bb43-d07684ceff72', request_type: 'N')
    { 'id' => id, 'eventType' => 'Transaction', 'subEventType' => 'SALE', 'requestType' => request_type, 'signature' => nil, 'version' => '1.0',
      'createdDt' => '2026-11-03 08:53:39',
      'data' => { 'dba' => 'Herbal store', 'tpn' => TPN, 'tpnLabel' => '', 'maskedPan' => '424242******4242', 'rrn' => '428209503179', 'txName' => 'SALE',
                  'transactionId' => '41151701526138035220241008151118', 'externalReferenceId' => reference, 'amount' => 11.66, 'tipAmount' => 1.01,
                  'approvalCode' => 'TAS176', 'tpnBatchNumber' => '469', 'cardLabel' => 'VISA', 'sourceType' => 'TPOS', 'hostResponseCode' => '00',
                  'email' => 'shopper@example.com', 'phoneNumber' => '+19898989898', 'chName' => 'PAT CARDHOLDER', 'cardToken' => 'card-token-secret',
                  'txDate' => '2026-11-03', 'L2L3uploadflag' => 'No', 'TermId' => '75091651', 'Mid' => '888000003338', 'commMedia' => nil } }
  end

  def basic = "Basic #{Base64.strict_encode64("rupert:#{FEED_KEY}")}"

  def deliver(event, headers = {})
    post pos_webhook_path(@setting.id), params: event.to_json, headers: { 'Content-Type' => 'application/json' }.merge(headers)
  end

  test 'a Basic-authenticated sale is stored without card or personal data' do
    deliver(sale_event, 'Authentication' => basic)
    assert_response :ok
    row = DejavooFeedEvent.sole
    assert_equal ['Transaction', 'SALE', 1166, 101, '469', 'VISA', '4242', 'TAS176', '2026-11-03'],
      [row.event_type, row.sub_event_type, row.amount_cents, row.tip_cents, row.batch_number, row.card_label, row.card_last_four, row.approval_code, row.occurred_on]
    stored = row.attributes.to_json
    ['424242', 'PAT CARDHOLDER', 'shopper@example.com', '9898989898', 'card-token-secret'].each { |secret| assert_not_includes stored, secret }
    assert_nil row.matched_kind, 'a sale Rupert did not send is flagged as from outside Rupert'
    # Tip attribution fields (time & pay: tips): the clerk number and terminal, never the card holder.
    assert_equal ['75091651', nil, nil], [row.terminal_id, row.performed_by, row.invoice_number]
  end

  test 'the clerk number and invoice on a FEED sale are kept and the tip is attributed off the request' do
    event = sale_event(id: 'clerk-sale-1')
    event['data'].merge!('performedBy' => '12', 'invoiceNumber' => 'INV-0042', 'deviceModel' => 'P1')
    assert_enqueued_with(job: Tips::AttributeFeedEventJob) do
      deliver(event, 'Authentication' => basic)
    end
    assert_response :ok
    row = DejavooFeedEvent.sole
    assert_equal ['12', 'INV-0042', 'P1'], [row.performed_by, row.invoice_number, row.device_model]
    perform_enqueued_jobs
    assert_equal 1, TipAllocation.count, 'nobody clocked in: one unassigned row for the tip'
    assert TipAllocation.sole.unassigned?
    assert_equal 101, TipAllocation.sole.amount_cents
  end

  test 'a wrong key, no key or a forged signature is refused and nothing is stored' do
    deliver(sale_event, 'Authentication' => "Basic #{Base64.strict_encode64('rupert:wrong-key-000000000')}")
    assert_response :unauthorized
    deliver(sale_event)
    assert_response :unauthorized
    deliver(sale_event.merge('signature' => 'a' * 128))
    assert_response :unauthorized
    assert_empty DejavooFeedEvent.all
  end

  test 'an HMAC-signed event is accepted under either of Dejavoo published field orders' do
    event = sale_event
    %w[java js].each_with_index do |_variant, index|
      text = Pos::DejavooFeed.hmac_candidates(event)[index]
      deliver(event.merge('id' => "hmac-#{index}", 'signature' => OpenSSL::HMAC.hexdigest('SHA512', FEED_KEY, text.sub(event['id'], "hmac-#{index}"))))
      assert_response :ok
    end
    assert_equal 2, DejavooFeedEvent.count
  end

  test 'a repeat or update posting refreshes one row and events match the Rupert record they belong to' do
    user = users(:regular_user)
    display = PosDisplaySession.create!(user: user, location: @location)
    checkout = PosCheckout.create!(location: @location, user: user, pos_display_session: display, cart_revision: 1, reference: SecureRandom.hex(16),
      tender: 'card', gateway_provider: 'dejavoo_spin', gateway_fingerprint: @setting.payment_fingerprint, environment: 'sandbox', lines_json: [],
      subtotal_cents: 1005, tax_cents: 60, tip_cents: 101, total_cents: 1166)
    attempt = checkout.pos_payment_attempts.create!(invoice: 'RDrupertsale0001', nonce_digest: SecureRandom.hex(32), submitted_at: Time.current)
    deliver(sale_event(reference: attempt.invoice), 'Authentication' => basic)
    deliver(sale_event(reference: attempt.invoice, request_type: 'U'), 'Authentication' => basic)
    row = DejavooFeedEvent.sole
    assert_equal ['pos_payment_attempt', attempt.id, 'U'], [row.matched_kind, row.matched_id, row.request_type]
  end

  test 'a closed batch is recorded with its count and total' do
    settlement = { 'id' => 'b6a1f6c2-1111-4c7a-9d7e-000000000001', 'eventType' => 'Settlement', 'subEventType' => 'Batch Settlement', 'requestType' => 'N',
                   'version' => '1.0', 'createdDt' => '2026-11-03 23:00:00', 'tpn' => TPN, 'batchNumber' => '469', 'settlementDate' => '2026-11-03',
                   'settlementCount' => 12, 'settlementAmount' => 245.5, 'settlementTxnDetails' => [] }
    deliver(settlement, 'Authentication' => basic)
    assert_response :ok
    row = DejavooFeedEvent.sole
    assert_equal ['Settlement', '469', 12, 24_550], [row.event_type, row.batch_number, row.settlement_count, row.settlement_cents]
  end
end
