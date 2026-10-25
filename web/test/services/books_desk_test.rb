# frozen_string_literal: true

require 'test_helper'

class BooksDeskTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  test 'frames this week and last week around today' do
    saturday = Date.new(2026, 10, 17)
    desk = BooksDesk.new(today: saturday)
    assert_equal Date.new(2026, 10, 5), desk.focus_week
    assert_equal 5, desk.this_week_days.size
    assert_equal 7, desk.focus_days.size
    assert_nil desk.next_week
    assert_equal 6, desk.focus_days.first.stages.size
  end

  test 'days of the unfinished week wait for the weekly sign-off' do
    desk = BooksDesk.new(today: Date.new(2026, 10, 17))
    assert(desk.this_week_days.all? { |day| day.stages.last.state == :later })
    assert(desk.focus_days.all? { |day| day.stages.last.blocker == :week })
  end

  test 'quarterly and yearly money reports cover the whole period' do
    q = MoneyReconciliationReport.new(kind: 'quarterly', date: '2026-08-14')
    assert_equal [Date.new(2026, 7, 1), Date.new(2026, 9, 30)], [q.from, q.to]
    y = MoneyReconciliationReport.new(kind: 'yearly', date: '2026-08-14')
    assert_equal [Date.new(2026, 1, 1), Date.new(2026, 12, 31)], [y.from, y.to]
    assert_equal Date.new(2025, 12, 31), MoneyReconciliationReport.previous_period('yearly', today: Date.new(2026, 3, 2))
  end
  test 'weekly approval waits until daily reviews and closes are done' do
    stages = BooksDesk::STAGES.keys.map do |key|
      BooksDesk::Stage.new(key: key, state: key == :approved ? :todo : :done, blocker: key == :approved ? :week : nil)
    end
    day = BooksDesk::Day.new(day: Date.new(2026, 10, 5), orders: 1, totals: {}, stages: stages)
    assert day.daily_cleanup_complete?
    assert_not day.complete?
    assert_nil day.next_stage
    desk = BooksDesk.new(today: Date.new(2026, 10, 17))
    desk.stubs(:focus_days).returns(Array.new(7, day))
    task = desk.focus_tasks.find { |item| item.key == :days }
    assert task.done?
    assert_includes task.detail, 'Approve the week after the remaining chores'
    stages.find { |stage| stage.key == :closed }.state = :todo
    assert_not day.daily_cleanup_complete?
    assert_equal :closed, day.next_stage.key
  end

  test 'day totals add sources within a currency and say so, never across currencies' do
    day = Date.new(2026, 10, 14)
    at = Time.zone.local(2026, 10, 14, 12)
    { 'square' => ['USD', 1500], 'shopify' => ['USD', 2500], 'swipesimple' => ['CAD', 700] }.each do |source, (currency, cents)|
      order = Core::Order.new(source: source, source_order_id: SecureRandom.uuid, currency: currency,
        gross_cents: cents, tax_cents: 0, occurred_at: at)
      order[:status] = 'paid'
      order.save!
    end
    row = BooksDesk.new(today: Date.new(2026, 10, 17)).this_week_days.find { |d| d.day == day }
    assert_equal({ 'CAD' => 700, 'USD' => 4000 }, row.totals)
    assert_equal({ 'CAD' => ['swipesimple'], 'USD' => %w[shopify square] }, row.sources)

    helper = ApplicationController.new.view_context
    assert_equal 'SwipeSimple: CAD 7.00 · All sources combined (Shopify, Square): $40.00',
      helper.books_desk_totals(row.totals, row.sources)
    assert_equal 'No sales recorded', helper.books_desk_totals({})
  end
end
