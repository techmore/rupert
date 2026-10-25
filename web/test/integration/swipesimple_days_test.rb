# frozen_string_literal: true

require 'test_helper'

class SwipesimpleDaysTest < ActionDispatch::IntegrationTest
  HEADER = 'Transaction #,Date,Type,Amount,Result,Method,Brand,Merchant Account,Tip Amount'
  ROWS = [
    'SYN-1,10/14/2026 9:00 AM,Sale,$50.00,Approved,Swiped,Visa,Example Wholesale,$5.00',
    'SYN-2,10/14/2026 10:00 AM,Sale,$20.00,Approved,Cash,,Example Wholesale,$0.00',
    'SYN-3,10/14/2026 11:00 AM,Sale,$30.00,Approved,Dipped,Mastercard,Example Wholesale,',
    'SYN-4,10/14/2026 12:00 PM,Sale,$99.00,Declined,Dipped,Visa,Example Wholesale,'
  ].freeze

  setup do
    @tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    travel_to Time.iso8601('2026-10-16T03:00:00Z')
    post login_path, params: { email: @admin.email, password: 'password' }
  end

  teardown do
    travel_back
    Current.reset
  end

  test 'daily close shows totals tender split checks deposit status and the transaction table' do
    import(ROWS)
    get swipesimple_days_path(date: '2026-10-14')
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_select 'h1', 'SwipeSimple daily close'
    assert_select '[aria-label="Daily SwipeSimple summary"]', text: /Approved sales.*\$100\.00/m
    assert_select '[aria-label="SwipeSimple totals by account and tender"] tbody tr', 2
    assert_select '[aria-label="SwipeSimple cash and card split"] td', text: '$80.00'
    assert_select '[data-check="unknown_tips"]'
    assert_select '#close-deposit', text: /deposit isn’t available/
    assert_select '.report-table[data-report-table-key-value="swipesimple-day"] tbody tr', 4
    assert_select 'a[href=?][aria-label="Previous day"]', swipesimple_days_path(date: '2026-10-13')
    assert_select 'a[href=?][aria-label="Next day"]', swipesimple_days_path(date: '2026-10-15')
    assert_select 'form[action=?] input[name=source_digest]', review_swipesimple_days_path
  end

  test 'register close shows all four requested boxes from native daily sales reports' do
    import(ROWS)
    SwipesimpleSalesDay.create!(merchant_account: 'Example Wholesale', business_date: '2026-10-14',
      net_sales_cents: 10_700, tax_cents: 600, net_card_cents: 8000, net_cash_cents: 2700,
      tips_cents: 100, source_digest: 'synthetic-register-close', pulled_at: Time.current)
    before = SwipesimpleReportRow.unscoped.count
    get swipesimple_days_path(date: '2026-10-14')
    assert_response :success
    { 'net_sales_cents' => ['Total collected', '$107.00'], 'tax_cents' => ['Sales tax collected', '$6.00'],
      'net_card_cents' => ['Credit card collected', '$80.00'], 'net_cash_cents' => ['Cash collected', '$27.00'] }.each do |field, (label, value)|
      assert_select "[data-register-total=#{field}] .stat-label", label
      assert_select "[data-register-total=#{field}] .stat-value", value
    end
    assert_select '[aria-label="Daily SwipeSimple summary"]', text: /Approved sales.*\$100\.00/m
    assert_equal before, SwipesimpleReportRow.unscoped.count
    assert_select '[data-register-account="Example Wholesale"]', text: /report pulled/
  end

  test 'register boxes show each merchant account on its own and never a combined total' do
    import(ROWS)
    SwipesimpleSalesDay.create!(merchant_account: 'Example Wholesale', business_date: '2026-10-14',
      net_sales_cents: 852_450, tax_cents: 0, net_card_cents: 852_450, net_cash_cents: 0,
      tips_cents: 0, source_digest: 'synthetic-card-account', pulled_at: Time.current)
    SwipesimpleSalesDay.create!(merchant_account: 'Example Terminal', business_date: '2026-10-14',
      net_sales_cents: 140_169, tax_cents: 5660, net_card_cents: 78_747, net_cash_cents: 61_422,
      tips_cents: 0, source_digest: 'synthetic-terminal', pulled_at: Time.current)
    SwipesimpleSalesDay.create!(merchant_account: 'Example Quiet', business_date: '2026-10-14',
      net_sales_cents: 0, tax_cents: 0, net_card_cents: 0, net_cash_cents: 0,
      tips_cents: 0, source_digest: 'synthetic-quiet', pulled_at: Time.current)
    get swipesimple_days_path(date: '2026-10-14')
    assert_response :success
    assert_select '[data-register-account="Example Terminal"] [data-register-total=net_sales_cents] .stat-value', '$1,401.69'
    assert_select '[data-register-account="Example Terminal"] [data-register-total=net_cash_cents] .stat-value', '$614.22'
    assert_select '[data-register-account="Example Wholesale"] [data-register-total=net_sales_cents] .stat-value', '$8,524.50'
    assert_select '[data-register-account="Example Quiet"]', text: /no sales on this report/
    assert_select '[data-register-account="Example Quiet"] [data-register-total]', 0
    assert_select '[data-register-total=net_sales_cents] .stat-value', count: 2
    assert_select '[aria-label="Register close totals"] .stat-value', text: '$9,926.19', count: 0
  end

  test 'missing native reports keep register boxes unknown for readers too' do
    import(ROWS)
    reader = User.create!(email: 'ss-register-reader@example.invalid', password: 'password123', role: 'reader', tenant: @tenant)
    switch_to(reader)
    get swipesimple_days_path(date: '2026-10-14')
    assert_response :success
    assert_select '[aria-label="Register close totals"] .stat-value', text: 'Unknown', count: 4
    assert_select '[aria-label="Register close totals"] input', count: 0
  end

  test 'empty day says no data and links to the connection' do
    get swipesimple_days_path(date: '2026-10-14')
    assert_response :success
    assert_includes response.body, 'That does not prove a zero-sales day'
    assert_select '[data-check="stale"]'
    assert_select 'a[href=?]', pos_connection_path('swipesimple')
    get swipesimple_days_path(date: 'not-a-date')
    assert_redirected_to swipesimple_days_path
  end

  test 'csv lists every transaction of the day with excluded rows marked' do
    import(ROWS)
    get swipesimple_days_path(date: '2026-10-14', format: :csv)
    assert_response :success
    assert_equal 'text/csv', response.media_type
    lines = response.body.lines
    assert_equal 5, lines.size
    assert lines.first.start_with?('BusinessDate,OccurredAt,Account')
    assert(lines.any? { |line| line.include?('SYN-4') && line.include?('no (excluded)') })
    assert(lines.any? { |line| line.include?('SYN-3') && line.include?('30.00,Unknown,yes') })
  end

  test 'local review needs a note for flags and is invalidated when the export changes' do
    import(ROWS)
    get swipesimple_days_path(date: '2026-10-14')
    digest = Nokogiri::HTML(response.body).at_css('input[name=source_digest]')['value']
    assert_no_difference 'SwipesimpleDayReview.unscoped.count' do
      post review_swipesimple_days_path, params: { date: '2026-10-14', source_digest: digest, note: '' }
      post review_swipesimple_days_path, params: { date: '2026-10-14', source_digest: 'stale', note: 'Checked' }
    end
    assert_difference 'SwipesimpleDayReview.unscoped.count', 1 do
      post review_swipesimple_days_path, params: { date: '2026-10-14', source_digest: digest, note: 'Tip for SYN-3 confirmed with staff.' }
    end
    assert_redirected_to swipesimple_days_path(date: Date.new(2026, 10, 14))
    follow_redirect!
    assert_select '#close-review', text: /Current version reviewed/
    Current.tenant = @tenant
    review = SwipesimpleDayReview.sole
    assert_equal [@admin.id, digest, 'Tip for SYN-3 confirmed with staff.'], [review.reviewed_by_id, review.reviewed_digest, review.review_note]
    assert SwipesimpleDayClose.new(Date.new(2026, 10, 14)).reviewed?

    import(ROWS.map { |row| row.start_with?('SYN-1,') ? row.sub('$50.00', '$55.00') : row }, exported_at: '2026-10-15T22:30:00-04:00')
    assert_not SwipesimpleDayClose.new(Date.new(2026, 10, 14)).reviewed?
    get swipesimple_days_path(date: '2026-10-14')
    assert_select '#close-review', text: /Review needed.*changed since/m
    post review_swipesimple_days_path, params: { date: '2026-10-14', source_digest: digest, note: 'Old view' }
    assert_equal digest, review.reload.reviewed_digest, 'a review of the old data cannot be recorded'
  end

  test 'settings writers choose the funding merchant from a masked list; others see a read-only line' do
    import(ROWS)
    retail = '000000004321'
    other = '000000008765'
    Current.tenant = @tenant
    [[retail, '2026-10-15', '80.00'], [other, '2026-10-15', '999.00']].each do |merchant, date, amount|
      IrisReport.create!(api_origin: 'https://fixture.iriscrm.com', merchant_number: merchant, report_kind: 'daily_deposits_csv',
        window_from: '2026-10-01', window_to: '2026-10-31', status: 'complete', observed_at: 1.hour.ago,
        payload_json: { 'currency' => nil, 'data' => [{ 'date' => date, 'amount' => amount, 'batch' => 'SYN' }] }.to_json)
    end

    get swipesimple_days_path(date: '2026-10-14')
    assert_select 'select[name=merchant_token] option', text: 'NAB merchant ••4321'
    assert_select 'select[name=merchant_token] option', text: 'NAB merchant ••8765'
    assert_not_includes response.body, retail
    assert_not_includes response.body, other

    post deposit_merchant_swipesimple_days_path, params: { date: '2026-10-14', merchant_token: 'not-a-merchant' }
    Current.tenant = @tenant
    assert_equal '', TenantSettings.swipesimple_deposit_merchant
    post deposit_merchant_swipesimple_days_path, params: { date: '2026-10-14', merchant_token: SwipesimpleDayClose.merchant_token(retail) }
    assert_redirected_to swipesimple_days_path(date: '2026-10-14', anchor: 'close-deposit')
    Current.tenant = @tenant
    assert_equal retail, TenantSettings.swipesimple_deposit_merchant

    get swipesimple_days_path(date: '2026-10-14')
    assert_select 'select[name=merchant_token] option[selected]', text: 'NAB merchant ••4321'
    assert_select '[data-deposit-amount]', '$80.00'
    assert_select '[data-deposit-difference]', '$0.00'
    assert_not_includes response.body, 'not a verified variance'
    assert_not_includes response.body, '$999.00'

    reader = User.create!(email: 'ss-merchant-reader@example.invalid', password: 'password123', role: 'manager', tenant: @tenant)
    switch_to(reader)
    get swipesimple_days_path(date: '2026-10-14')
    assert_select 'select[name=merchant_token]', count: 0
    assert_select '[data-deposit-merchant]', text: /NAB merchant ••4321/
    post deposit_merchant_swipesimple_days_path, params: { date: '2026-10-14', merchant_token: SwipesimpleDayClose.merchant_token(other) }
    assert_response :forbidden
    Current.tenant = @tenant
    assert_equal retail, TenantSettings.swipesimple_deposit_merchant
  end

  test 'sales readers can view but not review, others are refused' do
    import(ROWS)
    reader = User.create!(email: 'ss-reader@example.invalid', password: 'password123', role: 'reader', tenant: @tenant)
    switch_to(reader)
    get swipesimple_days_path(date: '2026-10-14')
    assert_response :success
    assert_select '#close-review', count: 0
    post review_swipesimple_days_path, params: { date: '2026-10-14', source_digest: 'x', note: 'x' }
    assert_response :forbidden

    stock = User.create!(email: 'ss-stock@example.invalid', password: 'password123', role: 'inventory_employee', tenant: @tenant)
    switch_to(stock)
    get swipesimple_days_path(date: '2026-10-14')
    assert_response :redirect
    assert_equal 0, SwipesimpleDayReview.unscoped.count
  end

  test 'sits in the Sell area next to C-Trax daily close and is linked from the close pages' do
    assert_equal 'sell', ModuleRegistry.area_key_for('swipesimple_days')
    keys = ModuleRegistry.nav_for(@admin).map(&:key)
    assert_equal keys.index('ctrax_days') + 1, keys.index('swipesimple_days')
    reader = User.create!(email: 'ss-nav@example.invalid', password: 'password123', role: 'inventory_employee', tenant: @tenant)
    refute_includes ModuleRegistry.nav_for(reader).map(&:key), 'swipesimple_days'

    get swipesimple_days_path
    assert_select 'nav[aria-label="Module"] a[aria-current="page"]', 'SwipeSimple daily close'
    get ctrax_days_path(date: '2026-10-14')
    assert_select 'a[href=?]', swipesimple_days_path(date: '2026-10-14')
    import(ROWS)
    get daily_reconciliations_path(day: '2026-10-14')
    assert_select 'a[href=?]', swipesimple_days_path(date: '2026-10-14')
  end

  test 'day close shows Shopify and Authorize.net and SwipeSimple as separate sections' do
    import(ROWS)
    SwipesimpleSalesDay.create!(merchant_account: 'Example Wholesale', business_date: '2026-10-14',
      net_sales_cents: 10_700, tax_cents: 600, net_card_cents: 8000, net_cash_cents: 2700,
      tips_cents: 100, source_digest: 'synthetic-combined-close', pulled_at: Time.current)
    settled = Time.zone.parse('2026-10-14 16:00')
    AuthorizeNetTransaction.create!(environment: 'production', gateway_id: 'gw-synthetic', source_transaction_id: 'anet-1',
      transaction_type: 'authCaptureTransaction', payment_status: 'settledSuccessfully', submitted_at: settled - 1.hour,
      settled_at: settled, authorized_amount: '42.50', settled_amount: '42.50', currency: 'USD', observed_at: settled)
    order = Core::Order.new(source: 'shopify', source_order_id: SecureRandom.uuid, occurred_at: Time.zone.parse('2026-10-14 12:00'),
      gross_cents: 1100, tax_cents: 100, currency: 'USD')
    order.aasm.current_state = :paid
    order.save!

    get financial_close_path(day: '2026-10-14')
    assert_response :success
    assert_select '#daily-close-stores' do
      assert_select 'h3', 'Shopify and Authorize.net'
      assert_select '[aria-label^="Store sales"] tbody th', text: /Shopify/
      assert_select '[data-authorize-net-row="gw-synthetic"]', text: /42\.50.*1 payment.*42\.50/m
      assert_select '[data-register-total]', 0
      assert_select 'th', text: 'SwipeSimple register', count: 0
    end
    assert_select '#daily-close-swipesimple' do
      assert_select 'h3', 'SwipeSimple'
      assert_select '[data-register-total=net_sales_cents] .stat-value', '$107.00'
      assert_select '[data-register-total=tax_cents] .stat-value', '$6.00'
      assert_select '[data-register-total=net_card_cents] .stat-value', '$80.00'
      assert_select '[data-register-total=net_cash_cents] .stat-value', '$27.00'
      assert_select '[aria-label^="SwipeSimple transaction totals"] th', text: /SwipeSimple register/
      assert_select 'a[href=?]', swipesimple_days_path(date: '2026-10-14')
      assert_select '[data-authorize-net-row]', 0
    end

    get swipesimple_days_path(date: '2026-10-14')
    assert_select 'a[href=?]', financial_close_path(day: '2026-10-14', anchor: 'daily-close-swipesimple')
  end

  test 'day close keeps SwipeSimple boxes unknown without a report and hides the sales link from report-only readers' do
    import(ROWS)
    bookkeeper = User.create!(email: 'ss-books@example.invalid', password: 'password123', role: 'reporting', tenant: @tenant)
    bookkeeper.update_permission_overrides!(%w[dashboard.read reports.read])
    switch_to(bookkeeper)
    get financial_close_path(day: '2026-10-14')
    assert_response :success
    assert_select '#daily-close-swipesimple [data-register-total=net_sales_cents] .stat-value', 'Unknown'
    assert_select '#daily-close-stores', text: /No Authorize\.net settlements are stored for this day/
    assert_select 'a[href^=?]', swipesimple_days_path, count: 0
  end

  test 'card tenders matched section pairs Rupert card tenders and lists both unmatched sides' do
    import(ROWS)
    get swipesimple_days_path(date: '2026-10-14')
    assert_select '#close-tenders [data-tender-match=none]', text: /Rupert recorded no card tenders on Oct 14, 2026\..*2 SwipeSimple card sales/m

    Current.tenant = @tenant
    at = ActiveSupport::TimeZone['America/New_York'].parse('2026-10-14 09:02')
    order = Core::Order.create!(source: 'rupert_pos', source_order_id: 'synthetic-pos-1', order_number: 'RP-1', channel: 'pos',
      currency: 'USD', occurred_at: at, gross_cents: 5000, tax_cents: 0, tip_cents: 0)
    order.payments.create!(method: 'card', amount_cents: 5000, status: 'completed', paid_at: at, reference: 'synthetic')
    order.payments.create!(method: 'card', amount_cents: 1111, status: 'completed', paid_at: at, reference: 'synthetic-2')
    Current.reset
    get swipesimple_days_path(date: '2026-10-14')
    assert_response :success
    assert_select '#close-tenders [data-tender-count=matched]', text: /1 matched/
    assert_select '#close-tenders [data-tender-pair]', 1
    assert_select '#close-tenders [data-tender-pair]', text: /SYN-1/
    assert_select '#close-tenders [data-tender-unmatched=rupert]', text: /RP-1.*\$11\.11/m
    assert_select '#close-tenders [data-tender-unmatched=swipesimple]', text: /SYN-3/
    assert_select '#close-tenders .pill-clay', 'Needs attention'
  end

  private

  def switch_to(user)
    delete logout_path
    post login_path, params: { email: user.email, password: 'password123' }
  end

  def import(rows, exported_at: '2026-10-15T22:00:00-04:00')
    Current.tenant = @tenant
    csv = ([HEADER] + rows).join("\n") + "\n"
    options = { kind: 'transactions', merchant_account: 'Example Wholesale', currency: 'USD',
      source_timezone: 'America/New_York', exported_at: exported_at }
    prepared = SwipesimpleReportImporter.preview(csv, options)
    SwipesimpleReportImporter.import!(csv, options, expected_fingerprint: prepared.fingerprint)
  end
end
