# frozen_string_literal: true

# Business figures computed once, in Ruby, from Rupert's own data (issue #357), so the MCP tools, the API, team
# chat bots and reports quote the same answer instead of a language model doing arithmetic.
#
# Every metric is per currency (currencies are never added together), takes a period (named preset or from/to),
# and is compared with the period before or the same dates last year, with the change already worked out.
# Orders are Rupert's canonical order store (Shopify, Square, Rupert POS, manual); paid and fulfilled orders,
# including later-refunded sales with refund evidence, count as sales. C-Trax and SwipeSimple snapshots are not
# orders and are never added in. Unknown is not zero.
module Metrics
  COUNTED = %w[paid fulfilled].freeze
  SOURCES = %w[shopify square rupert_pos manual pos].freeze
  COMPARES = %w[previous last_year none].freeze
  PRESETS = %w[today yesterday this_week last_week this_pay_week last_pay_week this_month last_month
               this_quarter last_quarter year_to_date last_year].freeze
  MAX_DAYS = 400

  Definition = Data.define(:key, :title, :unit, :description)

  CATALOG = [
    Definition.new('gross_sales', 'Gross sales', 'money', 'Paid and fulfilled orders, including later refunds, gross, per currency, with each source.'),
    Definition.new('orders', 'Orders', 'count', 'Number of paid and fulfilled orders, including later refunds, per currency, with each source.'),
    Definition.new('average_order_value', 'Average order value', 'money', 'Gross sales divided by orders, per currency.'),
    Definition.new('best_day', 'Best sales day', 'day', 'The day with the highest gross sales in the period (and its orders).'),
    Definition.new('worst_day', 'Slowest sales day', 'day', 'The day with the lowest gross sales among days with stored sales in the period (and its orders).'),
    Definition.new('sales_by_weekday', 'Sales by weekday', 'share', 'Gross, orders, days with sales and average per sales day for each weekday, with its share.'),
    Definition.new('sales_by_source', 'Sales by source', 'share', 'Gross and orders per source and its share of the currency total.'),
    Definition.new('top_products', 'Top products', 'share', 'The ten products with the most revenue, with units and share of product revenue.'),
    Definition.new('refund_rate', 'Refund rate', 'percent', 'Refunds recorded in the period as a percent of gross sales, with the amount and count.'),
    Definition.new('expenses_by_category', 'Expenses by category', 'money', 'Active expense-register totals by category, in USD.'),
    Definition.new('tax_collected', 'Sales tax collected', 'money', 'Sales tax recorded on paid and fulfilled orders, per currency, with each source.'),
    Definition.new('effective_tax_rate', 'Effective tax rate', 'percent', 'Recorded sales tax as a percent of sales before tax, per currency, with each source.')
  ].freeze

  module_function

  def catalog = CATALOG

  def find(key) = CATALOG.find { |metric| metric.key == key.to_s }

  # name: a catalog key. period or from/to: the window. compare: previous | last_year | none. source: one source.
  def call(name, period: nil, from: nil, to: nil, compare: 'previous', source: nil, today: Date.current)
    metric = find(name) or raise ArgumentError, "Unknown metric #{name.to_s.first(40)}. Use one of: #{CATALOG.map(&:key).join(', ')}."
    compare = compare.presence || 'previous'
    raise ArgumentError, "compare must be one of: #{COMPARES.join(', ')}." unless COMPARES.include?(compare)
    raise ArgumentError, "source must be one of: #{SOURCES.join(', ')}." if source.present? && !SOURCES.include?(source)
    if source.present? && metric.key == 'expenses_by_category'
      raise ArgumentError, 'source filtering is not available for expenses_by_category.'
    end

    window = Window.resolve(period: period, from: from, to: to, today: today)
    other = { 'previous' => window.previous, 'last_year' => window.last_year }[compare]
    now = compute(metric.key, window, source)
    before = compute(metric.key, other, source) if other
    result = { metric: metric.key, title: metric.title, unit: metric.unit, description: metric.description,
               period: window.as_json, source: source.presence, values: now[:values] }
    if other
      result[:compared_with] = other.as_json.merge(kind: compare, values: before[:values])
      result[:change] = change(metric, now[:values], before[:values])
    end
    result[:caveats] = caveats(metric.key, now, source)
    result[:text] = sentence(metric, window, other, compare, result)
    result
  end

  # --- computations ---

  def compute(key, window, source)
    orders = counted(window, source)
    case key
    when 'gross_sales', 'orders', 'average_order_value', 'sales_by_source' then { values: per_currency(orders, key) }
    when 'best_day' then { values: best_day(orders) }
    when 'worst_day' then { values: worst_day(orders) }
    when 'sales_by_weekday' then { values: sales_by_weekday(orders) }
    when 'top_products' then { values: top_products(orders) }
    when 'refund_rate' then { values: refund_rate(orders, window, source) }
    when 'expenses_by_category' then { values: expenses_by_category(window) }
    when 'tax_collected', 'effective_tax_rate' then { values: tax_by_currency(orders, key) }
    end
  end

  def counted(window, source)
    scope = Core::Order.where(occurred_at: window.times, source: source.presence || SOURCES)
    # A later refund does not erase the original gross sale. Canceled imports can
    # also have status refunded, so require evidence of an actual refund.
    refunded = scope.where(status: 'refunded').where(
      'orders.source_financial_status IN (?) OR orders.id IN (?)',
      %w[REFUNDED PARTIALLY_REFUNDED], Core::Refund.select(:order_id))
    scope.where(status: COUNTED).or(refunded)
  end

  def per_currency(orders, key)
    rows = orders.group(:currency, :source).pluck(:currency, :source, Arel.sql('COUNT(*)'), Arel.sql('SUM(gross_cents)'), Arel.sql('COUNT(gross_cents)'))
    rows.group_by(&:first).sort_by { |currency, _| currency.to_s }.map do |currency, list|
      count = list.sum { |row| row[2] }
      known = list.all? { |row| row[4] == row[2] }
      gross = known ? list.sum { |row| row[3].to_i } : nil
      sources = list.map do |_, source, n, cents, k|
        amount = k == n ? cents.to_i : nil
        { source: source, orders: n, gross_cents: amount, gross: money(amount, currency),
          share_percent: (gross&.positive? && amount ? (amount * 100.0 / gross).round(1) : nil) }
      end.sort_by { |row| -row[:gross_cents].to_i }
      value = case key
              when 'orders' then count
              when 'average_order_value' then (gross / count.to_f).round if gross && count.positive?
              else gross
              end
      formatted = key == 'orders' ? count.to_s : (value.nil? ? 'unknown (gross not recorded on every order)' : money(value, currency))
      { currency: currency, value: value, formatted: formatted,
        orders: count, gross_cents: gross, sources: sources }
    end
  end

  # { currency => { date => [gross_cents, orders] } }, days in the workspace time zone. Only days with stored orders.
  def daily_totals(orders)
    by_currency = Hash.new { |hash, key| hash[key] = Hash.new { |inner, day| inner[day] = [0, 0] } }
    orders.in_batches(of: 1000) do |batch|
      batch.pluck(:currency, :occurred_at, :gross_cents).each do |currency, at, cents|
        day = by_currency[currency][at.in_time_zone.to_date]
        day[0] = cents.nil? || day[0].nil? ? nil : day[0] + cents
        day[1] += 1
      end
    end
    by_currency.sort_by { |currency, _| currency.to_s }
  end

  def best_day(orders)
    daily_totals(orders).map do |currency, days|
      next unknown_daily_row(currency, days) if days.values.any? { |amount, _| amount.nil? }

      day_row(currency, days, days.max_by { |date, (amount, _)| [amount, -date.jd] })
    end
  end

  # Lowest of the days that have stored sales: a day with no stored orders is unknown, not a zero-sales day.
  def worst_day(orders)
    daily_totals(orders).map do |currency, days|
      next unknown_daily_row(currency, days) if days.values.any? { |amount, _| amount.nil? }

      day_row(currency, days, days.min_by { |date, (amount, _)| [amount, date.jd] })
    end
  end

  def unknown_daily_row(currency, days)
    { currency: currency, value: nil, formatted: "#{currency.presence || 'USD'}: unknown (gross not recorded on every order)",
      gross_cents: nil, gross: nil, orders: nil, days_with_sales: days.size }
  end

  def day_row(currency, days, (date, (cents, count)))
    { currency: currency, value: date.iso8601, formatted: "#{date.strftime('%A %b %-d, %Y')}: #{money(cents, currency)} from #{count} orders",
      gross_cents: cents, gross: money(cents, currency), orders: count, days_with_sales: days.size }
  end

  # Weekdays Monday first; only weekdays that have stored sales are listed.
  def sales_by_weekday(orders)
    daily_totals(orders).map do |currency, days|
      if days.values.any? { |amount, _| amount.nil? }
        next unknown_daily_row(currency, days).except(:gross, :orders).merge(weekdays: [])
      end

      total = days.values.sum(&:first)
      weekdays = days.group_by { |date, _| date.cwday }.sort.map do |cwday, list|
        cents = list.sum { |_, (amount, _)| amount }
        { weekday: Date::DAYNAMES[cwday % 7], gross_cents: cents, gross: money(cents, currency),
          orders: list.sum { |_, (_, count)| count }, days_with_sales: list.size,
          average_per_sales_day_cents: (cents / list.size.to_f).round,
          average_per_sales_day: money((cents / list.size.to_f).round, currency),
          share_percent: (total.positive? ? (cents * 100.0 / total).round(1) : nil) }
      end
      ranked = weekdays.sort_by { |row| [-row[:gross_cents], Date::DAYNAMES.index(row[:weekday])] }
      { currency: currency, value: ranked.first[:weekday],
        formatted: ranked.map { |row| "#{row[:weekday]} #{row[:gross]}#{" (#{row[:share_percent]}%)" if row[:share_percent]}" }.join(', '),
        gross_cents: total, days_with_sales: days.size, weekdays: weekdays }
    end
  end

  def top_products(orders)
    lines = Core::OrderLine.where(order_id: orders.select(:id)).joins(:order)
    lines.group('orders.currency').pluck(Arel.sql('orders.currency'), Arel.sql('SUM(order_lines.line_cents)'),
      Arel.sql('COUNT(*)'), Arel.sql('COUNT(order_lines.line_cents)')).sort_by { |currency, _, _, _| currency.to_s }.map do |currency, total, count, known|
      if count != known
        next { currency: currency, value: nil, formatted: 'unknown (revenue not recorded on every line)', products: [] }
      end
      top = lines.where(orders: { currency: currency }).group(:name)
                 .pluck(:name, Arel.sql('SUM(order_lines.line_cents)'), Arel.sql('SUM(order_lines.quantity)'))
                 .sort_by { |row| -row[1].to_i }.first(10)
                 .map do |name, cents, units|
                   { name: name, revenue_cents: cents.to_i, revenue: money(cents.to_i, currency), units: units.to_i,
                     share_percent: (total.to_i.positive? ? (cents.to_i * 100.0 / total.to_i).round(1) : nil) }
                 end
      { currency: currency, value: top.first&.dig(:name), formatted: top.first(3).map { |row| "#{row[:name]} (#{row[:revenue]})" }.join(', '),
        products: top }
    end
  end

  def refund_rate(orders, window, source)
    gross = orders.group(:currency).pluck(:currency, Arel.sql('SUM(gross_cents)'), Arel.sql('COUNT(*)'), Arel.sql('COUNT(gross_cents)'))
                  .to_h { |currency, total, count, known| [currency, known == count ? total.to_i : nil] }
    refunds = Core::Refund.joins(:order).where(refunded_at: window.times)
    refunds = refunds.where(orders: { source: source }) if source.present?
    refunded = refunds.group('orders.currency').pluck(Arel.sql('orders.currency'), Arel.sql('COUNT(*)'), Arel.sql('SUM(refunds.amount_cents)')).to_h { |currency, n, cents| [currency, [n, cents.to_i]] }
    (gross.keys | refunded.keys).compact.sort.map do |currency|
      sales = gross[currency]
      count, cents = refunded.fetch(currency, [0, 0])
      rate = sales&.positive? ? (cents * 100.0 / sales).round(2) : nil
      reason = sales.nil? ? 'unknown (gross sales not fully recorded)' : 'unknown (no sales)'
      { currency: currency, value: rate, formatted: (rate ? "#{rate}%" : reason), refunds: count,
        refunded_cents: cents, refunded: money(cents, currency), gross_cents: sales, gross: money(sales, currency) }
    end
  end

  # Expenses are recorded in USD and dated by incurred_on. Use the active,
  # tenant-scoped expense register; vendor payments settle payables and must
  # not be counted as a second expense.
  def expenses_by_category(window)
    rows = Finance::Expense.where(incurred_on: window.from..window.to)
                           .group(:category)
                           .pluck(:category, Arel.sql('SUM(amount_cents)'), Arel.sql('COUNT(*)'))
    return [] if rows.empty?

    names = Finance::ExpenseCategory.where(key: rows.map(&:first)).pluck(:key, :name).to_h
    categories = rows.sort_by { |key, cents, _count| [-cents.to_i, key] }.map do |key, cents, count|
      amount = cents.to_i
      { key: key, name: names[key] || key.to_s.tr('_', ' ').titleize,
        amount_cents: amount, formatted: money(amount), expenses: count,
        share_percent: nil }
    end
    total = categories.sum { |category| category[:amount_cents] }
    if total.positive?
      categories.each do |category|
        category[:share_percent] = (category[:amount_cents] * 100.0 / total).round(1)
      end
    end
    [{ currency: 'USD', value: total, formatted: money(total),
       expense_count: categories.sum { |category| category[:expenses] }, categories: categories }]
  end

  # Tax as recorded on each order by its source; sales before tax are gross minus that tax. One unrecorded (NULL)
  # amount makes the source, and its currency, unknown: never counted as zero.
  def tax_by_currency(orders, key)
    rows = orders.group(:currency, :source).pluck(:currency, :source, Arel.sql('COUNT(*)'), Arel.sql('SUM(gross_cents)'),
      Arel.sql('COUNT(gross_cents)'), Arel.sql('SUM(tax_cents)'), Arel.sql('COUNT(tax_cents)'))
    rows.group_by(&:first).sort_by { |currency, _| currency.to_s }.map do |currency, list|
      sources = list.map { |_, source, n, gross, gross_n, tax, tax_n| tax_row(currency, n, gross_n == n ? gross.to_i : nil, tax_n == n ? tax.to_i : nil).merge(source: source) }
                    .sort_by { |row| [-row[:tax_cents].to_i, row[:source]] }
      known = ->(field) { sources.all? { |row| row[field] } ? sources.sum { |row| row[field] } : nil }
      total = tax_row(currency, sources.sum { |row| row[:orders] }, known.call(:gross_cents), known.call(:tax_cents))
      field = key == 'tax_collected' ? :tax : :rate_text
      breakdown = sources.map { |row| "#{row[:source]} #{row[field] || 'unknown'}" }.join(', ')
      value = key == 'tax_collected' ? total[:tax_cents] : total[:effective_rate_percent]
      formatted = if key == 'tax_collected'
        total[:tax] || 'unknown (not recorded on every order)'
      else
        total[:rate_text] ? "#{total[:rate_text]} (#{total[:tax]} tax on #{total[:sales_before_tax]} before tax)" : 'unknown'
      end
      { currency: currency, value: value, formatted: "#{formatted} (#{breakdown})" }
        .merge(total.except(:rate_text)).merge(sources: sources.map { |row| row.except(:rate_text) })
    end
  end

  def tax_row(currency, count, gross, tax)
    before = gross && tax ? gross - tax : nil
    rate = (tax * 100.0 / before).round(2) if tax && before&.positive?
    { orders: count, tax_cents: tax, tax: money(tax, currency), gross_cents: gross, gross: money(gross, currency),
      sales_before_tax_cents: before, sales_before_tax: money(before, currency), effective_rate_percent: rate,
      rate_text: ("#{rate}%" if rate) }
  end

  # --- comparison and wording ---

  def change(metric, now, before)
    return [] unless %w[money count percent].include?(metric.unit)

    now.filter_map do |row|
      prior = before.find { |candidate| candidate[:currency] == row[:currency] }
      value = row[:value]
      old = prior&.dig(:value)
      next { currency: row[:currency], direction: 'unknown' } if value.nil? || old.nil?

      delta = value - old
      entry = { currency: row[:currency], change_amount: delta.is_a?(Float) ? delta.round(2) : delta,
                direction: delta.positive? ? 'up' : (delta.negative? ? 'down' : 'flat'),
                change_percent: (old.to_f.zero? ? nil : (delta * 100.0 / old).round(1)) }
      entry[:formatted] = case metric.unit
                          when 'money' then "#{entry[:direction]} #{money(delta.abs, row[:currency])}#{" (#{signed(entry[:change_percent])}%)" if entry[:change_percent]}"
                          when 'count' then "#{entry[:direction]} #{delta.abs}#{" (#{signed(entry[:change_percent])}%)" if entry[:change_percent]}"
                          else "#{entry[:direction]} #{delta.abs.round(2)} percentage points"
                          end
      entry
    end
  end

  def caveats(key, now, source)
    list = if key == 'expenses_by_category'
      ["Active entries in Rupert's USD expense register only; removed expenses and vendor payments are excluded."]
    else
      ['Only orders stored in Rupert (Shopify, Square, Rupert POS, manual). C-Trax and SwipeSimple are separate and not added in.']
    end
    list << 'Currencies are separate; never add them together.' if now[:values].size > 1
    list << "Only the #{source} source." if source.present?
    if now[:values].empty?
      list << if key == 'expenses_by_category'
        'No active expense records in this period; that does not prove there was no money out.'
      else
        'No stored orders in this period: that does not prove zero sales (a sync may be missing).'
      end
    end
    list << 'Refunds are counted by refund date; some refund sales from an earlier period.' if key == 'refund_rate'
    if %w[tax_collected effective_tax_rate].include?(key)
      list << 'Tax is as recorded by each source on its orders; Rupert does not recompute it, and tax on refunds is not subtracted. ' \
              'A source that does not record tax may show $0.00. Store register tax (C-Trax, SwipeSimple) is in sales_tax_report.'
      list << 'Sales before tax are gross sales minus the recorded tax. Unknown amounts stay unknown, never zero.'
    end
    if key == 'effective_tax_rate'
      list << 'This is recorded tax divided by sales before tax. It is not the configured tax rate; untaxed or exempt items lower it.'
    end
    if key == 'worst_day'
      list << 'Lowest of the days with stored sales. Days with no stored orders are unknown, not zero, and are not counted.'
    end
    if key == 'sales_by_weekday'
      list << 'Weekdays are business days in the workspace time zone. Averages are per day with stored sales; days with no ' \
              'stored orders are unknown and not counted, and a weekday that is not listed had no stored orders (not proof of zero sales).'
    end
    list
  end

  def sentence(metric, window, other, compare, result)
    if result[:values].empty?
      empty_reason = metric.key == 'expenses_by_category' ? 'no active expense records' : 'no stored orders'
      return "#{metric.title}, #{window.label} (#{window.from} to #{window.to}): #{empty_reason}."
    end

    parts = result[:values].map do |row|
      change = Array(result[:change]).find { |entry| entry[:currency] == row[:currency] }
      against = other && (compare == 'last_year' ? 'the same dates last year' : "the period before (#{other.from} to #{other.to})")
      formatted = row[:formatted]
      if metric.key == 'expenses_by_category'
        breakdown = row[:categories].first(5).map do |category|
          "#{category[:name]} #{category[:formatted]}"
        end
        remaining = row[:categories].length - breakdown.length
        breakdown << "#{remaining} more categories" if remaining.positive?
        formatted = "#{formatted} by category: #{breakdown.join(', ')}" unless breakdown.empty?
      end
      "#{formatted}#{", #{change[:formatted]} vs #{against}" if change && change[:formatted]}"
    end
    "#{metric.title}, #{window.label} (#{window.from} to #{window.to}): #{parts.join('; ')}."
  end

  # Assistant/MCP text: ASCII minus, other currencies after the amount ("5.00 CAD").
  def money(cents, currency = 'USD')
    Money.format(cents, currency: currency.presence || 'USD', code: :suffix, minus: '-', missing: nil)
  end

  def signed(number) = number.to_f.positive? ? "+#{number}" : number.to_s
end
