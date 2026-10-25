# frozen_string_literal: true

require 'test_helper'

# Money.format / Money.parse replace a dozen local formatters. Each test pins
# a former implementation (copied verbatim as a lambda) against the helper
# that now delegates, over the same amounts, so the refactor is provably
# output-identical. Where the old code produced "$-1.50" (sign after the
# unit) the new output is "-$1.50"; those cases are asserted explicitly.
class MoneyFormatTest < ActionView::TestCase
  include FinanceHelper
  include OperationsWorkspaceHelper
  include CtraxHelper
  include ReconciliationHelper
  include WorkItemsHelper
  include CustomersHelper

  AMOUNTS = [0, 1, 5, 99, 100, 101, 1234, 12_345, 123_456, 1_000_000, 123_456_789, 199_999_999_999,
             -1, -99, -100, -12_345, -123_456_789].freeze
  POSITIVE = AMOUNTS.reject(&:negative?).freeze

  def assert_same_value(expected, actual, message = nil)
    expected.nil? ? assert_nil(actual, message) : assert_equal(expected, actual, message)
  end

  test 'format follows ui-standards: dollars, delimiters, real minus, Unknown for nil' do
    assert_equal '$1,234.56', Money.format(123_456)
    assert_equal '−$0.01', Money.format(-1)
    assert_equal '$0.00', Money.format(0)
    assert_equal 'Unknown', Money.format(nil)
    assert_equal 'CAD 5.00', Money.format(500, currency: 'CAD')
    assert_equal '5.00 CAD', Money.format(500, currency: 'CAD', code: :suffix)
    assert_equal 'Unknown currency 5.00', Money.format(500, currency: nil)
    assert_equal '1,234.56', Money.format(123_456, unit: false)
    assert_equal '—', Money.format(0, zero: :dash)
    assert_equal '$1234.56', Money.format(123_456, delimiter: '')
    assert_equal '$0.13', Money.format(BigDecimal('12.5')), 'fractional cents round half up'
    assert_equal '$0.12', Money.format('12')
  end

  test 'parse reads typed amounts exactly and refuses anything else' do
    assert_equal 650, Money.parse('6.5')
    assert_equal 50, Money.parse('.50')
    assert_equal 123_450, Money.parse(' $1,234.50 ')
    assert_equal(-250, Money.parse('-2.50'))
    assert_nil Money.parse('-2.50', negative: false)
    assert_nil Money.parse('1.234')
    assert_nil Money.parse('abc')
    assert_nil Money.parse('')
    assert_nil Money.parse(nil)
    assert_nil Money.parse('$5', pattern: /\A\d{1,9}(?:\.\d{1,2})?\z/), 'a strict pattern sees the text as typed'
    assert_equal 29, Money.parse('0.29')
  end

  test 'finance_money_text and cents_to_decimal are unchanged' do
    old = lambda do |cents, currency: 'USD', zero: :show, missing: '—'|
      next missing if cents.nil?

      cents = Integer(cents)
      next '—' if cents.zero? && zero == :dash

      whole, fraction = cents.abs.divmod(100)
      digits = "#{number_with_delimiter(whole)}.#{format('%02d', fraction)}"
      prefix = currency == 'USD' ? '$' : "#{currency.presence || 'Unknown currency'} "
      "#{cents.negative? ? '−' : ''}#{prefix}#{digits}"
    end
    old_decimal = lambda do |cents|
      next '' if cents.nil?

      whole, fraction = Integer(cents).abs.divmod(100)
      "#{'-' if Integer(cents).negative?}#{whole}.#{format('%02d', fraction)}"
    end
    (AMOUNTS + [nil]).each do |cents|
      ['USD', 'CAD', nil, ''].each do |currency|
        %i[show dash].each do |zero|
          assert_equal old.call(cents, currency: currency, zero: zero), finance_money_text(cents, currency: currency, zero: zero)
        end
      end
      assert_equal old_decimal.call(cents), FinanceHelper.cents_to_decimal(cents)
    end
    assert_equal 'n/a', finance_money_text(nil, missing: 'n/a')
  end

  test 'operations_money and customer_money are unchanged' do
    old = lambda do |cents, currency: 'USD'|
      next 'Unknown' if cents.nil?

      amount = BigDecimal(cents.to_s) / 100
      figure = number_with_precision(amount.abs, precision: 2, delimiter: ',')
      sign = amount.negative? ? '−' : ''
      next "#{sign}$#{figure}" if currency.to_s.upcase == 'USD'

      "#{sign}#{currency.presence || 'Unknown currency'} #{figure}"
    end
    (AMOUNTS + [nil, BigDecimal('12.5'), '1234']).each do |cents|
      ['USD', 'usd', 'EUR', nil].each { |currency| assert_equal old.call(cents, currency: currency), operations_money(cents, currency: currency) }
    end
    assert_equal 'CAD 5.00 · $12.34', customer_money({ 'USD' => 1234, 'CAD' => 500 })
  end

  test 'ctrax_money and reconciliation_money are unchanged' do
    old_ctrax = ->(value, currency) { value.nil? ? 'Unknown' : number_to_currency(BigDecimal(value.to_s) / 100, unit: currency == 'USD' ? '$' : "#{currency} ") }
    old_recon = ->(cents) { cents.nil? ? 'Unavailable' : number_with_precision(BigDecimal(cents.to_s) / 100, precision: 2, delimiter: ',') }
    (AMOUNTS + [nil]).each do |cents|
      %w[USD CAD].each { |currency| assert_equal old_ctrax.call(cents, currency), ctrax_money(cents, currency: currency) }
      assert_equal old_recon.call(cents), reconciliation_money(cents)
    end
  end

  test 'service formatters are unchanged' do
    old_currency = ->(cents) { ActiveSupport::NumberHelper.number_to_currency(cents / 100.0) }
    old_metrics = lambda do |cents, currency|
      next nil if cents.nil?

      amount = ActiveSupport::NumberHelper.number_to_delimited(format('%.2f', cents.abs / 100.0))
      currency.to_s.upcase == 'USD' || currency.blank? ? "#{'-' if cents.negative?}$#{amount}" : "#{'-' if cents.negative?}#{amount} #{currency}"
    end
    old_toolbox = ->(cents) { "#{'-' if cents.negative?}$#{ActiveSupport::NumberHelper.number_to_delimited(format('%.2f', cents.abs / 100.0))}" }
    old_tax = ->(cents) { cents.nil? ? 'unavailable' : ActiveSupport::NumberHelper.number_to_delimited(format('%.2f', BigDecimal(cents.to_s) / 100)) }
    old_mcp = ->(cents) { cents.nil? ? 'unavailable' : format('%.2f', cents / 100.0) }
    old_pay_csv = ->(cents) { format('%d.%02d', *cents.to_i.divmod(100)) }
    old_brief = ->(cents) { format('$%.2f', cents.to_f / 100.0) }
    old_1099 = ->(cents) { "$#{ActiveSupport::NumberHelper.number_to_delimited(format('%.2f', cents.to_i / 100.0))}" }
    old_result = lambda do |cents, currency|
      amount = number_with_delimiter(format('%.2f', cents.to_i / 100.0))
      currency.to_s == 'USD' ? "$#{amount}" : "#{amount} #{currency}"
    end

    metrics = Metrics
    toolbox = TeamChat::Toolbox.allocate
    tax = SalesTaxReport.allocate
    brief = OperationsBrief.allocate
    pdf = Finance::Form1099Pdf.allocate
    mcp = Mcp::Tool.allocate
    variants = ShopifyVariantsController.new
    desk = BooksDesk.allocate

    AMOUNTS.each do |cents|
      assert_equal old_currency.call(cents), desk.send(:money, cents)
      assert_equal old_currency.call(cents), variants.send(:format_cents, cents)
      %w[USD CAD].each { |currency| assert_equal old_metrics.call(cents, currency), metrics.send(:money, cents, currency) }
      assert_equal old_metrics.call(cents, nil), metrics.send(:money, cents, nil)
      assert_equal old_toolbox.call(cents), toolbox.send(:dollars, cents)
      assert_equal old_tax.call(cents), tax.send(:dollars, cents)
      assert_equal old_mcp.call(cents), mcp.send(:money, cents)
    end
    assert_nil metrics.send(:money, nil)
    assert_equal 'unavailable', tax.send(:dollars, nil)
    assert_equal 'unavailable', mcp.send(:money, nil)

    POSITIVE.each do |cents|
      assert_equal old_pay_csv.call(cents), PayRunCsv.money(cents)
      assert_equal old_brief.call(cents), brief.send(:money, cents)
      assert_equal old_1099.call(cents), pdf.send(:money, cents)
      %w[USD EUR].each { |currency| assert_equal old_result.call(cents, currency), result_money(cents, currency) }
    end
    # The former versions put the sign after "$" or (pay CSV) floored the dollars.
    assert_equal '-1.50', PayRunCsv.money(-150)
    assert_equal '-$1.50', brief.send(:money, -150)
    assert_equal '-$1.50', pdf.send(:money, -150)
    assert_equal '-$1.50', result_money(-150, 'USD')
  end

  test 'typed cost and journal amounts parse as before' do
    old_cost = lambda do |text|
      cleaned = text.to_s.strip.delete('$,').strip
      next nil unless cleaned.match?(/\A\d+(\.\d{1,2})?\z|\A\.\d{1,2}\z/)

      (BigDecimal(cleaned) * 100).round.to_i
    end
    format_rule = Finance::JournalEntriesController::AMOUNT_FORMAT
    old_journal = ->(value) { (text = value.to_s.strip).match?(format_rule) ? (BigDecimal(text) * 100).to_i : nil }
    journal = Finance::JournalEntriesController.new
    ['6', '6.5', '.50', '$1,234.50', ' 12.00 ', '-5', '+5', '1.234', 'abc', '', nil, '$ 7', '1 000', '999999999.99', '1000000000'].each do |text|
      assert_same_value old_cost.call(text), ItemCost.parse_cents(text), text.inspect
      assert_same_value old_journal.call(text), journal.send(:to_cents_or_nil, text), text.inspect
      assert_equal old_journal.call(text) || 0, journal.send(:to_cents, text), text.inspect
    end
  end
end
