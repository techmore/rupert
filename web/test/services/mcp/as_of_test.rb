# frozen_string_literal: true

require 'test_helper'

class AsOfTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.tenant = @tenant
    Current.user = @user
    @token = TeamChat::Token.new(@user)
  end

  teardown { Current.reset }

  def call(tool, args = {}) = Mcp::Registry.find(tool).new(token: @token).call(args)

  def order(at:, cents:)
    row = Core::Order.create!(source: 'shopify', source_order_id: "t-#{SecureRandom.hex(3)}", order_number: "##{SecureRandom.hex(3)}",
      occurred_at: at, gross_cents: cents, tax_cents: 0, currency: 'USD', channel: 'online')
    row.mark_paid!
    row
  end

  test 'period_review resolves last_month from as_of whatever the real date is' do
    ['2026-11-15', '2027-03-02'].each do |real_day|
      travel_to Time.zone.parse("#{real_day} 12:00") do
        data = call('period_review', { 'period' => 'last_month', 'as_of' => '2026-10-27' }).data
        assert_equal ['2026-09-01', '2026-09-30'], [data[:from], data[:to]]
        assert_equal '2026-10-27', data[:as_of]
      end
    end
  end

  test 'metric last_month and the default period follow as_of' do
    order(at: Time.zone.parse('2026-09-10 12:00'), cents: 4200)
    travel_to Time.zone.parse('2027-01-20 09:00') do
      %w[last_month].push(nil).each do |period|
        args = { 'name' => 'gross_sales', 'compare' => 'none', 'as_of' => '2026-10-27' }
        args['period'] = period if period
        data = call('metric', args).data
        assert_equal ['2026-09-01', '2026-09-30'], [data[:period][:from], data[:period][:to]]
        assert_equal '2026-10-27', data[:as_of]
        assert_match(/as of 2026-10-27/, data[:text])
        assert_equal 4200, data[:values].first[:gross_cents]
      end
    end
  end

  test 'sales_summary, sales_tax_report and time_keeping_report default dates follow as_of' do
    travel_to Time.zone.parse('2027-01-20 09:00') do
      summary = call('sales_summary', { 'as_of' => '2026-10-27' })
      assert_equal ['2026-09-28', '2026-10-27', '2026-10-27'], [summary.data[:from], summary.data[:to], summary.data[:as_of]]
      assert_match(/as of 2026-10-27/, summary.text)
      assert_equal ['2026-10-01', '2026-10-27'], call('sales_tax_report', { 'as_of' => '2026-10-27' }).data.values_at(:from, :to)
      assert_equal ['2026-10-01', '2026-10-31'], call('time_keeping_report', { 'as_of' => '2026-10-27' }).data.values_at(:from, :to)
    end
  end

  test 'explicit from and to are not changed by as_of' do
    with = call('sales_summary', { 'from' => '2026-08-01', 'to' => '2026-08-31', 'as_of' => '2026-10-27' }).data
    without = call('sales_summary', { 'from' => '2026-08-01', 'to' => '2026-08-31' }).data
    assert_equal ['2026-08-01', '2026-08-31'], with.values_at(:from, :to)
    assert_equal without, with.except(:as_of)
    assert_not without.key?(:as_of)
  end

  test 'daily_close defaults to the as_of day and refuses days after it' do
    data = call('daily_close', { 'as_of' => '2026-10-27' }).data
    assert_equal ['2026-10-27', '2026-10-27'], data.values_at(:from, :to)
    assert_raises(Mcp::ToolError) { call('daily_close', { 'to' => '2026-10-28', 'from' => '2026-10-27', 'as_of' => '2026-10-27' }) }
  end

  test 'absent as_of keeps the real current date and adds nothing' do
    data = call('period_review', { 'period' => 'yesterday' })
    assert_equal (Date.current - 1).iso8601, data.data[:from]
    assert_not data.data.key?(:as_of)
    assert_no_match(/as of/, data.text)
    assert_not call('business_pulse').data.key?(:as_of)
  end

  test 'business_pulse echoes as_of and dates the snapshot with it' do
    outcome = call('business_pulse', { 'as_of' => '2026-10-27' })
    assert_equal ['2026-10-27', '2026-10-27'], [outcome.data[:date], outcome.data[:as_of]]
    assert_match(/live, not as of 2026-10-27/, outcome.text)
  end

  test 'malformed or too-future as_of is rejected as invalid_arguments' do
    ['yesterday', '2026-13-45', '27/10/2026', (Date.current + 2).iso8601].each do |bad|
      %w[metric period_review sales_summary sales_tax_report daily_close time_keeping_report business_pulse].each do |tool|
        args = { 'as_of' => bad }
        args['name'] = 'gross_sales' if tool == 'metric'
        error = assert_raises(Mcp::ToolError, "#{tool} #{bad}") { call(tool, args) }
        assert_equal 'invalid_arguments', error.kind
      end
    end
    assert_nothing_raised { call('sales_summary', { 'as_of' => (Date.current + 1).iso8601 }) }
  end
end
