# frozen_string_literal: true

require 'test_helper'

# Card (A920): the cashier runs the card on the SwipeSimple Pax A920 terminal and
# records it in Rupert like cash. A completed card payment, no gateway call.
class PosCardA920Test < ActionDispatch::IntegrationTest
  HELP = 'Use this while card payments are taken on the A920 terminal, until Rupert handles card payments end to end.'

  setup do
    Current.tenant = tenants(:default_tenant)
    Finance::ChartOfAccounts.seed!
    @user = users(:regular_user)
    @location = Location.create!(source: 'ctrax', externalId: 'fixture/7', name: 'Checkout fixture')
    @snapshot = CtraxStockSnapshot.create!(location: @location, api_origin: 'https://fixture.api.cannatrax.net', store_id: '7', captured_at: Time.current,
      records_json: [{ 'id' => '3', 'name' => 'Tea', 'product_name' => 'Tea', 'price_cents' => 1005, 'tax_rate_mbp' => 600_000, 'quantity' => '4', 'manage_stock' => true, 'listed' => true }])
    PosConnection.create!(provider: 'ctrax', vendor_approved: true, credentials_json: { api_url: @snapshot.api_origin, api_username: 'fixture', api_password: 'private-fixture' }.to_json)
    @setting = PosSetting.create!(location: @location, cash_enabled: true)
    @register = Sales::PosSession.create!(location: @location, user: @user, name: 'Front', opened_at: Time.current)
    sign_in(@user)
    Ctrax::StockSync.stubs(:call).returns(stores: 1, variants: 1)
  end
  teardown { Current.reset }

  test 'recording an A920 card sale makes a completed card payment, tip included, with no gateway call' do
    pair_quote_and_confirm
    [Pos::Gateway, Pos::NmiGateway].each { |gateway| gateway.expects(:new).never }
    [Pos::CardPayment, Pos::NmiCardPayment].each { |payment| payment.expects(:call).never }
    post pos_checkouts_path, params: { display_id: @display.id, tender: 'card_a920', register_id: @register.id, total_cents: 1, tip_cents: 9000 }, as: :json
    assert_response :success
    body = response.parsed_body
    assert_equal %w[paid card_a920 Card\ (A920)], body.values_at('status', 'tender', 'tender_label')
    assert_equal [1166, 101], body.values_at('total_cents', 'tip_cents')
    assert_nil body['change_cents']
    checkout = PosCheckout.last
    payment = checkout.order.payments.sole
    assert_equal ['card', 1166, 'completed'], [payment.method, payment.amount_cents, payment.status]
    assert_equal "swipesimple_a920-#{checkout.reference}", payment.reference
    assert_equal 'rupert_pos', checkout.order.source
    assert_empty PosPaymentAttempt.all
    assert_not_requested :any, /.*/
    assert_equal [0, 1166], [@register.reload.cash_sales_cents.to_i, @register.card_sales_cents]
    # Ledger: a card receipt in card settlements receivable (1150), not cash.
    entry = Finance::JournalEntry.for_source('Core::Payment', payment.id).posted.sole
    assert_equal 1166, line_for(entry, '1150').debit_cents
    assert_nil entry.journal_lines.find_by(account_id: Finance::Account.find_by!(code: '1000').id)
    # A repeated tap returns the same receipt.
    post pos_checkouts_path, params: { display_id: @display.id, tender: 'card_a920', register_id: @register.id }, as: :json
    assert_response :success
    assert_equal 1, Core::Payment.count
    get pos_checkout_path(checkout)
    assert_select 'header .pill-fern', 'Paid'
    assert_includes response.body, 'Rupert sent no gateway charge'
    assert_select 'a[href=?]', order_path(checkout.order), 'Open order'
  end

  test 'the A920 sale appears in the SwipeSimple card tender match at the terminal amount' do
    pair_quote_and_confirm
    post pos_checkouts_path, params: { display_id: @display.id, tender: 'card_a920', register_id: @register.id }, as: :json
    assert_response :success
    payment = PosCheckout.last.order.payments.sole
    paid_local = payment.paid_at.in_time_zone('America/New_York')
    csv = "Transaction #,Date,Type,Amount,Result,Method,Brand,Merchant Account,Tip Amount\n" \
          "A920-1,#{paid_local.strftime('%-m/%-d/%Y %-I:%M %p')},Sale,$11.66,Approved,Dipped,Visa,Counter,$1.01\n"
    options = { kind: 'transactions', merchant_account: 'Counter', currency: 'USD', source_timezone: 'America/New_York', exported_at: 1.minute.from_now.iso8601 }
    SwipesimpleReportImporter.import!(csv, options, expected_fingerprint: SwipesimpleReportImporter.preview(csv, options).fingerprint)
    match = SwipesimpleDayClose.new(paid_local.to_date).tender_match
    assert_equal [[payment.id, 'A920-1']], match.pairs.map { |pair| [pair.tender.id, pair.row.source_number] }
    assert match.all_matched?
  end

  test 'the Card (A920) tender has an accessible ? help with the owner wording' do
    pair_quote_and_confirm
    get ctrax_pos_path(location_id: @location.id, display_id: @display.id)
    assert_response :success
    assert_select '.pos-tenders[role=group] [data-a920-tender]' do
      assert_select 'button.pos-tender[data-tender="card_a920"][aria-describedby="pos-a920-help-live"]:not([disabled])', 'Card (A920)'
      assert_select 'details.term[data-a920-help] > summary' do
        assert_select '.sr-only', 'What is Card (A920)?'
        assert_select '.term-mark[aria-hidden="true"]', '?'
      end
      assert_select '.term-panel[role=note] p#pos-a920-help-live', HELP
    end
    assert_select '[data-a920-steps][hidden]', /Run the total shown, tip included, on the A920 first/
    assert_select '[data-a920-unavailable]', false
  end

  test 'Card (A920) follows the cash switch, and the help shows before pairing too' do
    @setting.update!(cash_enabled: false)
    get ctrax_pos_path(location_id: @location.id)
    assert_select '[data-a920-tender] button.pos-tender[disabled]', 'Card (A920)'
    assert_select '[data-a920-tender] p#pos-a920-help-idle', HELP
    pair_quote_and_confirm
    get ctrax_pos_path(location_id: @location.id, display_id: @display.id)
    assert_select 'button.pos-tender[data-tender="card_a920"][disabled]'
    assert_select '[data-a920-unavailable]', /Card \(A920\) is off/
    post pos_checkouts_path, params: { display_id: @display.id, tender: 'card_a920', register_id: @register.id }, as: :json
    assert_response :unprocessable_entity
    assert_empty Core::Payment.all
  end

  test 'cashiers can record it; staff without POS access cannot' do
    cashier = User.create!(tenant: @user.tenant, email: 'a920-cashier@example.test', password: 'password', role: 'cashier')
    sign_in(cashier)
    @register.update!(user: cashier)
    pair_quote_and_confirm(cashier)
    post pos_checkouts_path, params: { display_id: @display.id, tender: 'card_a920', register_id: @register.id }, as: :json
    assert_response :success
    assert_equal 'card', Core::Payment.sole.method
    reader = User.create!(tenant: @user.tenant, email: 'a920-reader@example.test', password: 'password', role: 'reader')
    assert_not reader.can_use_pos?
    display = PosDisplaySession.create!(user: reader, location: @location)
    sign_in(reader)
    post pos_checkouts_path, params: { display_id: display.id, tender: 'card_a920', register_id: @register.id }, as: :json
    assert_response :redirect
    assert_equal 1, Core::Payment.count
  end

  test 'a refund is recorded on the order as card, like cash refunds, with no gateway call' do
    pair_quote_and_confirm
    post pos_checkouts_path, params: { display_id: @display.id, tender: 'card_a920', register_id: @register.id }, as: :json
    order = PosCheckout.last.order
    [Pos::Gateway, Pos::NmiGateway].each { |gateway| gateway.expects(:new).never }
    post refund_order_path(order), params: { amount: '11.66', method: 'card', reason: 'Refunded on the A920' }
    assert_redirected_to order_path(order)
    refund = order.refunds.sole
    assert_equal ['card', 1166], [refund.method, refund.amount_cents]
    assert order.reload.refunded?
    assert_not_requested :any, /.*/
    entry = Finance::JournalEntry.for_source('Core::Refund', refund.id).posted.sole
    assert_equal 1166, line_for(entry, '1150').credit_cents
  end

  test 'an unpaid A920 checkout can be cancelled, and the demo records nothing' do
    pair_quote_and_confirm
    checkout = Pos::Checkout.prepare!(display: @display.reload, tender: 'card_a920', register_id: @register.id)
    assert_equal 'ready', checkout.status
    post cancel_pos_checkout_path(checkout), as: :json
    assert_response :success
    assert_equal 'cancelled', checkout.reload.status
    assert_empty Core::Payment.all
    @display.reload.update!(demo: true)
    quote_and_confirm
    post pos_checkouts_path, params: { display_id: @display.id, tender: 'card_a920' }, as: :json
    assert_response :success
    assert_equal %w[paid card_a920], response.parsed_body.values_at('status', 'tender')
    assert_empty Core::Payment.all
  end

  private

  def sign_in(user)
    delete logout_path
    post login_path, params: { email: user.email, password: 'password' }
  end

  def line_for(entry, code) = entry.journal_lines.find_by!(account_id: Finance::Account.find_by!(code: code).id)

  def pair_quote_and_confirm(user = @user)
    @display = PosDisplaySession.create!(user: user, location: @location)
    quote_and_confirm
  end

  def quote_and_confirm
    post quote_ctrax_pos_path(@location.id, display_id: @display.id), params: { items: [{ variant_id: '3', quantity: 1 }] }, as: :json
    assert_response :success
    @display.reload
    post customer_display_tip_path, params: { display_token: @display.display_token, cart_revision: @display.cart_revision, choice: '10' }, as: :json
    assert_response :success
  end
end
