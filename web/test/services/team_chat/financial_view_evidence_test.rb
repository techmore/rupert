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
