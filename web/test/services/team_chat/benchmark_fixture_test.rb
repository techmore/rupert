# frozen_string_literal: true

require 'test_helper'

class TeamChatBenchmarkFixtureTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.tenant = @tenant
    Current.user = @user
  end

  teardown { Current.reset }

  # Loads the fixture in a savepoint that is rolled back, handing back its truth only.
  def truth_of_a_fresh_run(**options)
    truth = nil
    ActiveRecord::Base.transaction(requires_new: true) do
      truth = TeamChat::BenchmarkFixture.call(tenant: @tenant, **options).truth
      raise ActiveRecord::Rollback
    end
    truth
  end

  test 'two runs in fresh databases give identical truth, and a different seed gives different data' do
    first = truth_of_a_fresh_run
    assert_equal first, truth_of_a_fresh_run
    assert_equal first.to_json, truth_of_a_fresh_run.to_json
    assert_not_equal first['sales_by_month'], truth_of_a_fresh_run(seed: 7)['sales_by_month']
    assert_equal 0, Core::Order.where('source_order_id LIKE ?', 'bf-%').count
  end

  test 'a second call on the same tenant raises instead of doubling the data' do
    TeamChat::BenchmarkFixture.call(tenant: @tenant)
    count = Core::Order.count
    assert_raises(TeamChat::BenchmarkFixture::AlreadyLoaded) { TeamChat::BenchmarkFixture.call(tenant: @tenant) }
    assert_equal count, Core::Order.count
  end

  test 'it refuses to run in production unless explicitly allowed' do
    production = ActiveSupport::StringInquirer.new('production')
    Rails.stub(:env, production) do
      assert_raises(TeamChat::BenchmarkFixture::Refused) { TeamChat::BenchmarkFixture.call(tenant: @tenant) }
      assert_equal 0, Core::Order.where('source_order_id LIKE ?', 'bf-%').count
    end
  end

  test 'it writes nothing for any other tenant and the truth can be saved as JSON' do
    other = Tenant.create!(id: 'other-tenant', name: 'Other', subdomain: 'othershop')
    fixture = TeamChat::BenchmarkFixture.call(tenant: @tenant)
    path = Rails.root.join('tmp', "benchmark-truth-#{Process.pid}.json")
    fixture.truth_json(path)
    assert_equal fixture.truth, JSON.parse(File.read(path))
    assert_equal 0, Core::Order.tenant_unscoped(other.id).count + Finance::Expense.tenant_unscoped(other.id).count
  ensure
    FileUtils.rm_f(path)
  end

  test 'the data is rich enough for real questions' do
    truth = TeamChat::BenchmarkFixture.call(tenant: @tenant).truth
    counts = truth['counts']
    assert_operator counts['sales_orders'], :>=, 250
    assert_operator counts['sources'].size, :>=, 3
    assert_equal %w[CAD USD], counts['currencies']
    assert_operator counts['expenses'], :>=, 10
    assert_operator counts['employees'], :>=, 5
    assert_operator counts['products'], :>=, 20
    assert_operator counts['refunds'], :>=, 5
    assert_operator truth['refunds_by_month']['2026-09'].values.sum { |by_currency| by_currency.values.sum { |row| row['count'] } }, :>=, 3
    truth['best_weekday_last_quarter'].except('from', 'to').each do |currency, row|
      assert_operator row['best_gross_cents'], :>, row['runner_up_gross_cents'], "#{currency} needs one clear best weekday"
    end
    assert_equal %w[Saturday Wednesday], truth['best_weekday_last_quarter'].values_at('USD', 'CAD').map { |row| row['best'] }
    assert_equal 5, truth['top_products_sept_2026']['USD'].map { |row| row['revenue_cents'] }.uniq.size
    assert_operator truth['timesheets']['awaiting_approval'], :>=, 2
    assert_operator truth['timesheets']['overdue_approvals'].size, :>=, 2
    assert_equal ['Tea shelf count'], truth['tasks']['due_this_friday']
    assert_operator truth['tasks']['overdue_titles'].size, :>=, 3
    assert_operator truth['stock']['low_stock_products'].size, :>=, 3
    assert_operator truth['order_queues']['unpaid_orders'].size, :>=, 1
    assert_operator truth['order_queues']['paid_unshipped_orders'].size, :>=, 1
    assert_equal 14, truth['daily_orders_last_14_days'].size
    assert_operator truth['customers'].values.count { |row| row['orders'].positive? }, :>=, 5
  end

  test 'the database holds what the generator says it created' do
    fixture = TeamChat::BenchmarkFixture.call(tenant: @tenant)
    counts = fixture.truth['counts']
    assert_equal counts['orders'], Core::Order.count
    assert_equal counts['refunds'], Core::Refund.count
    assert_equal counts['expenses'], Finance::Expense.count
    assert_equal counts['timesheets'], People::Timesheet.count
    assert_equal counts['tasks'], Projects::Task.count
    assert_equal counts['customers'], Core::Customer.count
    assert_equal fixture.truth['stock']['open_alert_skus'], StockAlert.open.pluck(:sku).sort
    assert_equal fixture.truth['order_queues']['unpaid_orders'].sort, Core::Order.where(status: 'placed').pluck(:order_number).sort
  end

  # The key test: Rupert's own tools, run on the generated data, must agree with the generator's independent truth.
  test "Rupert's tools agree with the generator's truth" do
    fixture = TeamChat::BenchmarkFixture.call(tenant: @tenant)
    truth = fixture.truth
    token = TeamChat::Token.new(@user)
    travel_to Time.zone.local(2026, 10, 27, 12) do
      september = { 'from' => '2026-09-01', 'to' => '2026-09-30' }
      metric = ->(name, args = {}) { Mcp::Tools::Metric.new(token: token).call({ 'name' => name, 'compare' => 'none' }.merge(args)).data[:values] }
      sept = truth['sales_by_month']['2026-09']

      gross = metric.call('gross_sales', september)
      assert_equal sept.transform_values { |row| row['gross_cents'] }, gross.to_h { |row| [row[:currency], row[:gross_cents]] }
      assert_equal sept.transform_values { |row| row['orders'] }, metric.call('orders', september).to_h { |row| [row[:currency], row[:value]] }

      assert_equal sept.transform_values { |row| row['tax_cents'] }, metric.call('tax_collected', september).to_h { |row| [row[:currency], row[:tax_cents]] }
      assert_sources_match(sept, gross)

      top = metric.call('top_products', september).to_h { |row| [row[:currency], row[:products].first(5).map { |p| [p[:name], p[:units], p[:revenue_cents]] }] }
      truth['top_products_sept_2026'].except('mixed_currencies_like_sales_summary').each do |currency, rows|
        assert_equal rows.map { |p| [p['name'], p['units'], p['revenue_cents']] }, top[currency], "top products in #{currency}"
      end

      weekday = metric.call('sales_by_weekday', 'from' => '2026-07-01', 'to' => '2026-09-30').to_h { |row| [row[:currency], row[:value]] }
      assert_equal truth['best_weekday_last_quarter'].except('from', 'to').transform_values { |row| row['best'] }, weekday
    end
  end

  test "sales_summary, refunds, expenses, the daily series and the pay week agree with the truth" do
    fixture = TeamChat::BenchmarkFixture.call(tenant: @tenant)
    truth = fixture.truth
    token = TeamChat::Token.new(@user)
    travel_to Time.zone.local(2026, 10, 27, 12) do
      summary = Mcp::Tools::SalesSummary.new(token: token).call({ 'from' => '2026-09-01', 'to' => '2026-09-30', 'top_products' => 5 }).data
      # sales_summary counts only paid/fulfilled orders, so the one fully refunded order is taken out of the truth.
      refunded = truth['fully_refunded_orders'].select { |row| row['month'] == '2026-09' }
      expected = truth['sales_by_month']['2026-09'].to_h do |currency, row|
        gone = refunded.select { |order| order['currency'] == currency }
        [currency, [row['orders'] - gone.size, row['gross_cents'] - gone.sum { |order| order['gross_cents'] }]]
      end
      assert_equal expected, summary[:totals_by_currency].to_h { |row| [row[:currency], [row[:orders], row[:gross_cents]]] }

      daily = Mcp::Tools::SalesSummary.new(token: token).call({ 'from' => '2026-10-14', 'to' => '2026-10-27', 'include_daily' => true, 'top_products' => 0 }).data[:daily]
      assert_equal truth['daily_orders_last_14_days'].transform_values { |row| row['orders'] }, daily.to_h { |row| [row[:date], row[:orders]] }

      metric = ->(name, args) { Mcp::Tools::Metric.new(token: token).call({ 'name' => name, 'compare' => 'none' }.merge(args)).data[:values] }
      expenses = metric.call('expenses_by_category', 'from' => '2026-07-01', 'to' => '2026-10-27').first
      assert_equal truth['expenses']['total_cents'], expenses[:value]
      assert_equal truth['expenses']['by_category'], expenses[:categories].to_h { |row| [row[:key], row[:amount_cents]] }

      refunds = metric.call('refund_rate', 'from' => '2026-09-01', 'to' => '2026-09-30')
      expected_refunds = truth['refunds_by_month']['2026-09'].values.each_with_object(Hash.new(0)) do |by_currency, sums|
        by_currency.each { |currency, row| sums[currency] += row['count'] }
      end
      assert_equal expected_refunds, refunds.to_h { |row| [row[:currency], row[:refunds]] }

      week = metric.call('gross_sales', 'period' => 'last_week')
      assert_equal truth['weeks']['last_week']['gross_cents_by_currency'], week.to_h { |row| [row[:currency], row[:gross_cents]] }
    end
  end

  test "overdue tasks, low stock and staff hours read the same through Rupert's own records" do
    fixture = TeamChat::BenchmarkFixture.call(tenant: @tenant)
    truth = fixture.truth
    travel_to Time.zone.local(2026, 10, 27, 12) do
      assert_equal truth['tasks']['overdue_titles'].sort, Projects::Task.overdue.pluck(:title).sort
      assert_equal truth['timesheets']['awaiting_approval'], People::Timesheet.awaiting_review.count
      week = Date.parse(truth['timesheets']['last_pay_week']['from'])..Date.parse(truth['timesheets']['last_pay_week']['to'])
      hours = People::Employee.all.to_h { |employee| [employee.name, employee.timesheet_entries.where(worked_on: week).sum(:hours).to_f] }
      assert_equal truth['timesheets']['last_pay_week']['hours_by_employee'], hours
      assert_equal truth['stock']['low_stock_products'].sort,
        InventoryLevel.where('quantity <= ?', TenantSettings.low_stock_threshold_int).map { |level| level.shopify_variant.product.title }.sort
    end
  end

  def assert_sources_match(month, gross_rows)
    expected = month.transform_values { |row| row['by_source'].transform_values { |source| source['gross_cents'] } }
    actual = gross_rows.to_h { |row| [row[:currency], row[:sources].to_h { |source| [source[:source], source[:gross_cents]] }] }
    assert_equal expected, actual
  end
end
