# frozen_string_literal: true

require 'test_helper'

class TeamChatFinancialViewEvidenceTest < ActiveSupport::TestCase
  def setup
    @period = { 'from' => '2026-10-19', 'to' => '2026-10-25' }
    @facts = [
      { 'meaning' => 'Gross sales (paid or fulfilled orders)', 'unit' => 'money', 'value' => '72.0', 'currency' => 'USD',
        'source' => 'shopify canonical orders (paid or fulfilled)', 'period' => @period },
      { 'meaning' => 'Gross sales (paid or fulfilled orders)', 'unit' => 'money', 'value' => '40.0', 'currency' => 'USD',
        'source' => 'rupert_pos canonical orders (paid or fulfilled)', 'period' => @period }
    ]
    @evidence = [{ 'facts' => @facts, 'daily' => { 'period' => @period, 'rows' => [
      { 'date' => '2026-10-19', 'currency' => 'USD', 'orders' => 1, 'gross_cents' => 4000 },
      { 'date' => '2026-10-20', 'currency' => 'USD', 'orders' => 0, 'gross_cents' => nil },
      { 'date' => '2026-10-21', 'currency' => 'USD', 'orders' => 1, 'gross_cents' => 0 }
    ] } }]
  end

  def check(view, evidence = @evidence, question = 'Chart sales')
    TeamChat::FinancialViewEvidence.check(view.deep_stringify_keys, evidence, question: question)
  end

  test 'source chart fallback uses recorded source and currency values and rejects conflicts' do
    travel_to Time.zone.parse('2026-10-27 12:00') do
      question = "Show a bar chart of last week's recorded sales by source"
      view = TeamChat::FinancialViewEvidence.source_fallback(@evidence, question: question)
      assert_equal 'bar_chart', view['kind']
      assert_equal ['Source', 'Gross sales USD'], view['columns']
      assert_equal [['rupert_pos', '40.0'], ['shopify', '72.0']], view['rows']
      assert_nil check(view, @evidence, question)
      assert_nil TeamChat::FinancialViewEvidence.source_fallback(@evidence, question: 'Chart profit by source last week')
      assert_nil TeamChat::FinancialViewEvidence.source_fallback(@evidence, question: 'Chart Shopify sales by source last week')
      assert_nil TeamChat::FinancialViewEvidence.source_fallback(@evidence, question: 'Last week sales by source without a chart')
      assert_nil TeamChat::FinancialViewEvidence.source_fallback(@evidence, question: 'Chart sales by source for tea last week')
      assert_nil TeamChat::FinancialViewEvidence.source_fallback(@evidence, question: 'Chart USD sales by source last week')
      conflict = @evidence.deep_dup
      conflict.first['facts'] << conflict.first['facts'].first.merge('value' => '999')
      assert_nil TeamChat::FinancialViewEvidence.source_fallback(conflict, question: question)
    end
  end

  test 'daily trend fallback leaves missing days blank and preserves recorded zero' do
    travel_to Time.zone.parse('2026-10-27 12:00') do
      data = @evidence.deep_dup
      data.first['daily']['source'] = TeamChat::FinancialEvidence::ORDER_SOURCE
      data.first['daily']['omitted'] = false
      (22..25).each { |day| data.first['daily']['rows'] << { 'date' => "2026-10-#{day}", 'currency' => 'USD', 'orders' => 0, 'gross_cents' => nil } }
      question = "Plot last week's recorded sales trend"
      view = TeamChat::FinancialViewEvidence.daily_fallback(data, question: question)
      assert_equal 'line_chart', view['kind']
      assert_equal [['2026-10-19', '40.0'], ['2026-10-20', nil], ['2026-10-21', '0.0']], view['rows'].first(3)
      assert_nil check(view, data, question)
      incomplete = data.deep_dup
      incomplete.first['daily']['rows'].pop
      assert_nil TeamChat::FinancialViewEvidence.daily_fallback(incomplete, question: question)
      data.first['daily']['omitted'] = true
      assert_nil TeamChat::FinancialViewEvidence.daily_fallback(data, question: question)
      assert_nil TeamChat::FinancialViewEvidence.daily_fallback(@evidence, question: 'Plot Shopify sales trend last week')
      assert_nil TeamChat::FinancialViewEvidence.daily_fallback(@evidence, question: 'Last week sales trend without a chart')
      assert_nil TeamChat::FinancialViewEvidence.daily_period_for('Plot the sales trend for tea last week')
      assert_nil TeamChat::FinancialViewEvidence.daily_period_for('Plot USD sales trend last week')
      assert TeamChat::FinancialViewEvidence.daily_period_for('Plot the sales trend for last week')
    end
  end

  test 'daily chart accepts one bounded explicit date range without extra filters' do
    parser = TeamChat::FinancialViewEvidence
    assert_equal({ 'from' => '2026-08-01', 'to' => '2026-08-03' },
      parser.daily_period_for('Plot recorded daily gross sales for 2026-08-01 through 2026-08-03.'))
    assert_nil parser.daily_period_for('Plot daily sales for tea from 2026-08-01 through 2026-08-03.')
    assert_nil parser.daily_period_for('Plot daily sales by source from 2026-08-01 through 2026-08-03.')
    assert_nil parser.daily_period_for('Plot daily sales from 2026-08-01 through 2026-08-03 compared with the prior period.')
    assert_nil parser.daily_period_for('Plot daily sales from 2026-08-03 to 2026-08-01.')
    assert_nil parser.daily_period_for('Plot daily sales from 2026-08-01 to 2026-09-30.')
    assert_nil parser.daily_period_for('Plot daily sales from 2026-08-01 to 2026-08-03 versus 2026-07-01.')
  end

  test 'source chart ties the value to the source, currency, period and unit' do
    view = { kind: 'bar_chart', title: 'Sales 2026-10-19 to 2026-10-25', columns: ['Source', 'Gross sales USD'],
             rows: [['Shopify', 72], ['Rupert POS', 40]] }
    assert_nil check(view)
    safe = TeamChat::FinancialViewEvidence.with_safe_caption(view.deep_stringify_keys.merge('note' => 'All other sources are complete.'), @evidence, question: 'Chart sales')
    assert_includes safe['title'], 'Recorded sales by source'
    assert_includes safe['note'], 'Missing records do not prove zero or complete coverage'
    assert_not_includes safe['note'], 'All other sources are complete'
    view[:rows] = [['Shopify', 40], ['Rupert POS', 72]]
    assert_match(/source, currency, period and unit/, check(view))
    view[:rows] = [['Shopify', 72], ['Manual', 0]]
    assert_match(/source, currency, period and unit/, check(view))
    view[:rows] = [['Shopify', 72]]
    view[:columns][1] = 'Gross sales USD cents'
    assert_match(/source, currency, period and unit/, check(view))
    view[:rows] = [['Shopify', 7200]]
    assert_nil check(view)
    view[:rows] = [['Shopify', 7200], ['Shopify', 7200]]
    assert_match(/source is repeated/, check(view))
    view[:title] = 'Sales'
    assert_match(/one recorded period/, check(view))
  end

  test 'daily chart preserves unknown days and genuine zero-value orders' do
    view = { kind: 'line_chart', title: 'Sales 2026-10-19 to 2026-10-25', columns: ['Date', 'Gross sales USD', 'Orders'],
             rows: [['2026-10-19', 40, 1], ['2026-10-20', nil, 0], ['2026-10-21', 0, 1]] }
    assert_nil check(view)
    view[:rows][1][1] = 0
    assert_match(/missing days are not zero/, check(view))
    view[:rows] = [['2026-10-19', 112, 1]]
    assert_match(/date, currency, period and unit/, check(view))
    view[:rows] = [['Monday', 40, 1]]
    assert_match(/invalid or inconsistent/, check(view))
  end

  test 'a financial view without evidence is withheld and nonfinancial views are unaffected' do
    view = { kind: 'bar_chart', title: 'Gross sales', columns: ['Source', 'Gross sales USD'], rows: [['Shopify', 72]] }
    assert_match(/need recorded evidence/, check(view, []))
    nonfinancial = { kind: 'table', title: 'Alerts', columns: ['SKU', 'Quantity'], rows: [['SYN-TEA', 2]] }
    assert_nil check(nonfinancial, [], 'Show open stock alerts')
    assert_nil check(nonfinancial, @evidence, 'Show sales and open stock alerts')
    assert_match(/structured, verifiable/, check({ kind: 'html', title: 'Report', html: '<p>72</p>' }, [], 'Show sales in the side panel'))
  end

  test 'product revenue is attached to the correct product and currency' do
    facts = [{ 'meaning' => 'Product revenue: Tea', 'unit' => 'money', 'value' => '80.0', 'currency' => 'USD', 'period' => @period },
             { 'meaning' => 'Share of product revenue: Tea', 'unit' => 'percent', 'value' => '100.0', 'currency' => 'USD', 'period' => @period }]
    view = { kind: 'table', title: 'Products 2026-10-19 to 2026-10-25', columns: ['Product', 'Revenue USD', 'Share USD %'], rows: [['Tea', 80, 100]] }
    assert_nil check(view, [{ 'facts' => facts }], 'Show product revenue')
    view[:rows] = [['Coffee', 80, 100]]
    assert_match(/product or category/, check(view, [{ 'facts' => facts }], 'Show product revenue'))
  end
end
