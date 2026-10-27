# frozen_string_literal: true

require 'test_helper'

class MetricsTest < ActiveSupport::TestCase
  TODAY = Date.new(2026, 10, 22) # a Thursday

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
  end

  teardown { Current.reset }

  def order(day, cents, source: 'shopify', currency: 'USD', name: 'Tea 50g', paid: true, tax: 0)
    row = Core::Order.create!(source: source, source_order_id: SecureRandom.hex(4), occurred_at: day.in_time_zone.change(hour: 12),
      gross_cents: cents, tax_cents: tax, currency: currency)
    row.mark_paid! if paid
    row.order_lines.create!(name: name, sku: name.parameterize, unit_cents: cents, quantity: 1, line_cents: cents)
    row
  end

  def expense(day, cents, category: 'supplies')
    Finance::Expense.create!(payee: 'Metrics fixture', category: category, amount_cents: cents, incurred_on: day)
  end

  def metric(name, **options) = Metrics.call(name, today: TODAY, **options)

  test 'gross sales per currency, with each source, compared with the period before' do
    order(TODAY - 1, 10_000)
    order(TODAY - 1, 5_000, source: 'square')
    order(TODAY - 2, 6_000)
    order(TODAY - 1, 9_999, currency: 'CAD')
    order(TODAY - 1, 77_777, paid: false)

    result = metric('gross_sales', period: 'yesterday')
    usd = result[:values].find { |row| row[:currency] == 'USD' }
    assert_equal [15_000, '$150.00', 2], [usd[:value], usd[:formatted], usd[:orders]]
    assert_equal [['shopify', 66.7], ['square', 33.3]], usd[:sources].map { |row| [row[:source], row[:share_percent]] }
    change = result[:change].find { |row| row[:currency] == 'USD' }
    assert_equal ['up', 9_000, 150.0, 'up $90.00 (+150.0%)'], change.values_at(:direction, :change_amount, :change_percent, :formatted)
    assert_equal %w[CAD USD], result[:values].pluck(:currency), 'currencies are never added together'
    assert_equal({ label: 'Yesterday', from: '2026-10-21', to: '2026-10-21' }, result[:period])
    assert_equal '2026-10-20', result[:compared_with][:from]
    assert_match(/\AGross sales, Yesterday \(2026-10-21 to 2026-10-21\): 99\.99 CAD.*; \$150\.00, up \$90\.00 \(\+150\.0%\) vs the period before/, result[:text])
    assert_includes result[:caveats], 'Currencies are separate; never add them together.'
  end

  test 'orders, average order value, best day, sources, top products and refund rate' do
    order(TODAY - 10, 2_000, name: 'Mints')
    order(TODAY - 10, 4_000, name: 'Tea 50g')
    order(TODAY - 3, 10_000, name: 'Tea 50g', source: 'rupert_pos')
    refunded = order(TODAY - 3, 1_000, name: 'Mints')
    Core::Refund.create!(order: refunded, amount_cents: 1_000, refunded_at: (TODAY - 2).in_time_zone.change(hour: 9), method: 'card')

    window = { from: (TODAY - 29).iso8601, to: TODAY.iso8601 }
    assert_equal 4, metric('orders', **window)[:values].first[:value]
    assert_equal ['$42.50'], metric('average_order_value', **window)[:values].pluck(:formatted)
    best = metric('best_day', **window)[:values].first
    assert_equal ['2026-10-19', 11_000, 2], best.values_at(:value, :gross_cents, :orders)
    sources = metric('sales_by_source', **window)[:values].first[:sources]
    assert_equal [['rupert_pos', 58.8], ['shopify', 41.2]], sources.map { |row| [row[:source], row[:share_percent]] }
    top = metric('top_products', **window)[:values].first[:products]
    assert_equal [['Tea 50g', '$140.00', 82.4], ['Mints', '$30.00', 17.6]], top.map { |row| row.values_at(:name, :revenue, :share_percent) }
    refunds = metric('refund_rate', **window)[:values].first
    assert_equal [5.88, '5.88%', 1, '$10.00'], refunds.values_at(:value, :formatted, :refunds, :refunded)
    assert_equal [{ currency: 'USD', value: 10_000, formatted: '$100.00', orders: 1, gross_cents: 10_000,
                    sources: [{ source: 'rupert_pos', orders: 1, gross_cents: 10_000, gross: '$100.00', share_percent: 100.0 }] }],
      metric('gross_sales', **window, source: 'rupert_pos', compare: 'none')[:values]
  end

  test 'slowest day and sales by weekday only count days with stored sales, per currency' do
    order(TODAY - 10, 2_000) # Monday Oct 12
    order(TODAY - 10, 4_000) # Monday Oct 12
    order(TODAY - 3, 10_000) # Monday Oct 19
    order(TODAY - 5, 1_500)  # Saturday Oct 17
    order(TODAY - 2, 9_000, currency: 'CAD') # Tuesday Oct 20
    window = { from: (TODAY - 29).iso8601, to: TODAY.iso8601 }

    slow = metric('worst_day', **window)
    usd = slow[:values].find { |row| row[:currency] == 'USD' }
    assert_equal ['2026-10-17', 1_500, 1, 3], usd.values_at(:value, :gross_cents, :orders, :days_with_sales)
    assert_equal 'Saturday Oct 17, 2026: $15.00 from 1 orders', usd[:formatted]
    assert_equal %w[CAD USD], slow[:values].pluck(:currency), 'currencies are never added together'
    assert_match(/no stored orders are unknown, not zero/, slow[:caveats].join)
    assert_empty slow[:change], 'a day is not compared as an amount'

    weekly = metric('sales_by_weekday', **window)[:values].find { |row| row[:currency] == 'USD' }
    assert_equal ['Monday', 17_500, 3], weekly.values_at(:value, :gross_cents, :days_with_sales)
    assert_equal [['Monday', 16_000, 3, 2, 8_000, 91.4], ['Saturday', 1_500, 1, 1, 1_500, 8.6]],
      weekly[:weekdays].map { |row| row.values_at(:weekday, :gross_cents, :orders, :days_with_sales, :average_per_sales_day_cents, :share_percent) }
    assert_equal 'Monday $160.00 (91.4%), Saturday $15.00 (8.6%)', weekly[:formatted]
    assert_match(/workspace time zone/, metric('sales_by_weekday', **window)[:caveats].join)

    assert_empty metric('worst_day', period: 'last_quarter', compare: 'none')[:values]
    assert_empty metric('sales_by_weekday', period: 'last_quarter', compare: 'none')[:values]
  end

  test 'daily sales rankings are unknown when any order has no gross amount' do
    order(TODAY - 3, 10_000)
    missing = order(TODAY - 3, 5_000)
    missing.update_columns(gross_cents: nil)
    missing_first = order(TODAY - 4, 1_000)
    missing_first.update_columns(gross_cents: nil)
    order(TODAY - 4, 3_000)
    order(TODAY - 2, 2_000)
    order(TODAY - 2, 7_000, currency: 'CAD')
    window = { from: (TODAY - 7).iso8601, to: TODAY.iso8601, compare: 'none' }

    %w[best_day worst_day sales_by_weekday].each do |name|
      result = metric(name, **window)
      usd = result[:values].find { |row| row[:currency] == 'USD' }
      assert_nil usd[:value], name
      assert_nil usd[:gross_cents], name
      assert_match(/unknown.*gross not recorded/, usd[:formatted], name)
      assert_match(/unknown.*gross not recorded/, result[:text], name)
      refute_nil result[:values].find { |row| row[:currency] == 'CAD' }[:value], name
    end
    assert_empty metric('sales_by_weekday', **window)[:values].find { |row| row[:currency] == 'USD' }[:weekdays]
  end

  test 'refund rate is unknown when gross sales are incomplete or absent' do
    known = order(TODAY - 2, 10_000)
    missing = order(TODAY - 1, 1_000)
    missing.update_columns(gross_cents: nil)
    Core::Refund.create!(order: known, amount_cents: 1_000, refunded_at: (TODAY - 1).in_time_zone.change(hour: 9), method: 'card')
    order(TODAY - 1, 5_000, currency: 'CAD')

    result = metric('refund_rate', from: (TODAY - 2).iso8601, to: TODAY.iso8601, compare: 'none')
    usd = result[:values].find { |row| row[:currency] == 'USD' }
    assert_nil usd[:value]
    assert_nil usd[:gross_cents]
    assert_equal 1_000, usd[:refunded_cents]
    assert_match(/gross sales not fully recorded/, usd[:formatted])
    assert_equal 0.0, result[:values].find { |row| row[:currency] == 'CAD' }[:value]

    earlier = order(TODAY - 10, 3_000, source: 'rupert_pos')
    Core::Refund.create!(order: earlier, amount_cents: 500, refunded_at: (TODAY - 1).in_time_zone.change(hour: 9), method: 'card')
    no_sales = metric('refund_rate', from: (TODAY - 1).iso8601, to: (TODAY - 1).iso8601,
      source: 'rupert_pos', compare: 'none')
    assert_nil no_sales[:values].first[:value]
    assert_nil no_sales[:values].first[:gross_cents]
    assert_equal 500, no_sales[:values].first[:refunded_cents]
  end

  test 'same dates last year, an empty period, and bad requests' do
    order(TODAY - 1, 8_000)
    order((TODAY - 1).prev_year, 10_000)
    change = metric('gross_sales', period: 'yesterday', compare: 'last_year')[:change].first
    assert_equal ['down', -2_000, -20.0], change.values_at(:direction, :change_amount, :change_percent)

    empty = metric('orders', period: 'last_quarter', compare: 'none')
    assert_empty empty[:values]
    assert_match(/does not prove zero sales/, empty[:caveats].join)
    assert_nil empty[:change]

    assert_raises(ArgumentError) { metric('profit_margin') }
    assert_raises(ArgumentError) { metric('orders', period: 'last_decade') }
    assert_raises(ArgumentError) { metric('orders', compare: 'tomorrow') }
    assert_raises(ArgumentError) { metric('orders', from: '2026-10-10', to: '2026-10-01') }
  end

  test 'expenses by category uses active register entries and compares totals' do
    expense(TODAY - 1, 10_000, category: 'supplies')
    expense(TODAY - 1, 2_500, category: 'software')
    expense(TODAY - 2, 1_000, category: 'supplies')
    expense(TODAY, 90_000, category: 'software') # outside the requested period
    removed = expense(TODAY - 1, 80_000, category: 'rent')
    removed.discard!

    result = metric('expenses_by_category', period: 'yesterday')
    assert_equal [{ currency: 'USD', value: 12_500, formatted: '$125.00', expense_count: 2,
                    categories: [
                      { key: 'supplies', name: 'Supplies', amount_cents: 10_000, formatted: '$100.00', expenses: 1, share_percent: 80.0 },
                      { key: 'software', name: 'Software', amount_cents: 2_500, formatted: '$25.00', expenses: 1, share_percent: 20.0 }
                    ] }], result[:values]
    assert_equal ['USD', 11_500, 1_150.0, 'up $115.00 (+1150.0%)'], result[:change].first.values_at(:currency, :change_amount, :change_percent, :formatted)
    assert_match(/\$125\.00 by category: Supplies \$100\.00, Software \$25\.00/, result[:text])
    assert_includes result[:caveats].first, 'removed expenses and vendor payments are excluded'

    assert_raises(ArgumentError) { metric('expenses_by_category', period: 'yesterday', source: 'shopify') }
  end

  test 'expenses by category explains an empty period' do
    result = metric('expenses_by_category', period: 'last_quarter', compare: 'none')

    assert_empty result[:values]
    assert_match(/no active expense records/, result[:text])
    assert_match(/does not prove there was no money out/, result[:caveats].join)
    assert_nil result[:change]
  end

  test 'tax collected and effective tax rate per currency with each source, never added across currencies' do
    order(TODAY - 1, 10_800, tax: 800)
    order(TODAY - 1, 5_400, source: 'square', tax: 400)
    order(TODAY - 1, 11_300, currency: 'CAD', tax: 1_300)
    order(TODAY - 1, 99_999, tax: 9_999, paid: false)
    order(TODAY - 2, 5_250, tax: 250)

    tax = metric('tax_collected', period: 'yesterday')
    assert_equal %w[CAD USD], tax[:values].pluck(:currency), 'currencies are never added together'
    usd = tax[:values].find { |row| row[:currency] == 'USD' }
    assert_equal [1_200, '$12.00', 2, 15_000, '$150.00', 8.0], usd.values_at(:value, :tax, :orders, :sales_before_tax_cents, :sales_before_tax, :effective_rate_percent)
    assert_equal '$12.00 (shopify $8.00, square $4.00)', usd[:formatted]
    assert_equal [['shopify', 800, 10_000, 8.0], ['square', 400, 5_000, 8.0]],
      usd[:sources].map { |row| row.values_at(:source, :tax_cents, :sales_before_tax_cents, :effective_rate_percent) }
    assert_equal ['up', 950, 380.0], tax[:change].find { |row| row[:currency] == 'USD' }.values_at(:direction, :change_amount, :change_percent)
    assert_match(/as recorded by each source/, tax[:caveats].join)
    assert_match(/\ASales tax collected, Yesterday \(2026-10-21 to 2026-10-21\): 13\.00 CAD/, tax[:text])

    rate = metric('effective_tax_rate', period: 'yesterday')
    usd = rate[:values].find { |row| row[:currency] == 'USD' }
    assert_equal [8.0, '8.0% ($12.00 tax on $150.00 before tax) (shopify 8.0%, square 8.0%)'], usd.values_at(:value, :formatted)
    assert_equal 13.0, rate[:values].find { |row| row[:currency] == 'CAD' }[:value]
    change = rate[:change].find { |row| row[:currency] == 'USD' }
    assert_equal ['up', 3.0, 'up 3.0 percentage points'], change.values_at(:direction, :change_amount, :formatted)
    assert_match(/not the configured tax rate/, rate[:caveats].join)
    assert_equal 'rupert_pos', metric('tax_collected', period: 'yesterday', source: 'rupert_pos', compare: 'none')[:source]
  end

  test 'unrecorded tax is unknown, never zero, and an empty period says so' do
    order(TODAY - 1, 10_800, tax: 800)
    order(TODAY - 1, 5_000, source: 'square', tax: nil)

    usd = metric('tax_collected', period: 'yesterday', compare: 'none')[:values].first
    assert_nil usd[:value]
    assert_equal 'unknown (not recorded on every order) (shopify $8.00, square unknown)', usd[:formatted]
    assert_equal [['shopify', 800], ['square', nil]], usd[:sources].map { |row| row.values_at(:source, :tax_cents) }

    rate = metric('effective_tax_rate', period: 'yesterday')
    assert_nil rate[:values].first[:value]
    assert_equal 'unknown (shopify 8.0%, square unknown)', rate[:values].first[:formatted]
    assert_equal [{ currency: 'USD', direction: 'unknown' }], rate[:change]

    empty = metric('tax_collected', period: 'last_quarter', compare: 'none')
    assert_empty empty[:values]
    assert_match(/no stored orders/, empty[:text])
    assert_match(/does not prove zero sales/, empty[:caveats].join)
  end
end
