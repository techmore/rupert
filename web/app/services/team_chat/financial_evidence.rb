# frozen_string_literal: true

require 'bigdecimal'
require 'digest'
require 'json'

module TeamChat
  # Numeric resemblance is not evidence. Only explicit tool contracts produce
  # facts; Ruby renders their values AND meanings instead of trusting prose.
  module FinancialEvidence
    VERSION = 1
    CURRENCIES = %w[USD CAD EUR GBP AUD NZD CHF CNY HKD SGD MXN BRL ZAR INR].freeze
    TOOLS = %w[metric sales_summary period_review business_pulse sales_tax_report daily_close].freeze
    CONTRACTS = (TOOLS + %w[time_keeping_report purchase_orders order_queues]).freeze
    MEANINGS = {
      'gross_sales' => ['Gross sales (paid or fulfilled orders)', 'money'],
      'orders' => ['Paid or fulfilled order count', 'count'],
      'average_order_value' => ['Average gross order value', 'money'],
      'refund_rate' => ['Recorded refunds as a percentage of gross sales', 'percent'],
      'tax_collected' => ['Sales tax recorded on paid or fulfilled orders', 'money'],
      'effective_tax_rate' => ['Recorded sales tax as a percentage of sales before tax', 'percent'],
      'best_day' => ['Highest recorded sales day', 'money'],
      'worst_day' => ['Lowest recorded sales day', 'money'],
      'top_products' => ['Product revenue', 'money'],
      'expenses_by_category' => ['Active expense-register total (not profit)', 'money'],
      'sales_by_source' => ['Gross sales by source', 'money']
    }.freeze
    DAILY_CLOSE = [['net_cents', 'Daily-close net sales (gross minus refunds; before tax and tips)'],
                   ['gross_cents', 'Daily-close gross sales (after discounts, before tax and tips)'],
                   ['cash_cents', 'Daily-close cash'], ['card_cents', 'Daily-close card'],
                   ['tax_cents', 'Daily-close sales tax'], ['refunds_cents', 'Daily-close refunds'],
                   ['tips_cents', 'Daily-close tips']].freeze
    ORDER_SOURCE = 'canonical orders: Shopify, Square, Rupert POS and manual; C-Trax/SwipeSimple excluded'

    module_function

    def financial_data?(value)
      case value
      when Hash then value.any? { |key, inner| key.to_s.match?(/(?:_cents|_percent)\z/) || financial_data?(inner) }
      when Array then value.any? { |inner| financial_data?(inner) }
      else false
      end
    end

    def financial_text?(text)
      text.to_s.match?(/[$€£¥]|\d[\d,.]*\s*(?:%|dollars\b|[A-Z]{3}\b)|\b(?:USD|CAD|EUR|GBP|JPY)\s*-?\d/) ||
        (text.to_s.match?(/\d/) && text.to_s.match?(/\b(?:profit|revenue|sales|tax|expenses?|refunds?|margin|cash|balance|income)\b/i))
    end

    def build(tool:, data:, arguments:, tenant_id:, invocation:)
      data = data.deep_stringify_keys
      args = arguments.deep_stringify_keys
      out = { 'version' => VERSION, 'tool' => tool, 'tenant_id' => tenant_id, 'invocation' => invocation, 'facts' => [], 'gaps' => [] }
      case tool
      when 'metric'
        name = data['metric']
        raise ArgumentError unless name == args['name'] && MEANINGS.key?(name)

        expected = Metrics::Window.resolve(period: args['period'], from: args['from'], to: args['to'])
        period = window(data.fetch('period'), expected.from.iso8601, expected.to.iso8601)
        source = name == 'expenses_by_category' ? 'active Rupert expense register; vendor payments excluded' : order_source(data['source'])
        raise ArgumentError unless data['source'].presence == args['source'].presence

        if args['source'].present? && Array(data['values']).any? { |row| Array(row['sources']).any? { |part| part['source'] != args['source'] } }
          raise ArgumentError
        end
        metric_rows(out, data['values'], name, source, period, 'values')
        if name == 'expenses_by_category' && data['values'].is_a?(Array) && data['values'].empty?
          out['gaps'] << 'No active expense-register records were found for this period; vendor payments are excluded. ' \
                         'Profit cannot be established from this evidence.'
        end
        empty_current = data['values'].is_a?(Array) && data['values'].empty?
        if empty_current
          implicit = args['compare'].blank? ? ' An implicit prior-period comparison is omitted.' : ''
          out['gaps'] << "No metric rows were returned for the requested period (#{period['from']} to #{period['to']}; #{source})." \
                         "#{implicit} Missing rows do not prove zero."
        end
        if data['compared_with'] && !(empty_current && args['compare'].blank?)
          prior = { 'previous' => expected.previous, 'last_year' => expected.last_year }.fetch(args['compare'].presence || 'previous')
          old = window(data['compared_with'], prior.from.iso8601, prior.to.iso8601)
          metric_rows(out, data['compared_with']['values'], name, source, old, 'compared_with.values')
          if args['compare'].present? && data['values'].is_a?(Array) && data['compared_with']['values'].is_a?(Array)
            missing = data['values'].filter_map do |row|
              currency = row['currency']
              currency if CURRENCIES.include?(currency) && data['compared_with']['values'].none? { |prior_row| prior_row['currency'] == currency }
            end.uniq
            if missing.any?
              out['gaps'] << "No comparison metric rows were returned for #{missing.join(', ')} in #{old['from']} to #{old['to']}; missing rows do not prove zero."
            end
          end
          if args['compare'].present? && data['compared_with']['values'].is_a?(Array) && data['compared_with']['values'].empty?
            out['gaps'] << "No metric rows were returned for the comparison period (#{old['from']} to #{old['to']}; #{source}). " \
                           'Missing rows do not prove zero.'
          end
          Array(data['change']).each_with_index do |row, index|
            add(out, row['change_percent'], 'percent', row['currency'], source, period,
              "#{MEANINGS.fetch(name).first}: change versus #{old['from']} to #{old['to']} (not percentage points)", "change.#{index}.change_percent")
          end
        end
      when 'sales_summary'
        last = args['to'] || Date.current.iso8601
        first = args['from'] || (Date.iso8601(last) - 29).iso8601
        period = window(data, first, last)
        Array(data['lines']).each_with_index do |row, index|
          raise ArgumentError if args['source'].present? && row['source'] != args['source']

          source = order_source(row.fetch('source'))
          { 'gross_cents' => ['Gross sales (paid or fulfilled orders)', 'money'], 'tax_cents' => ['Order tax', 'money'], 'orders' => ['Paid or fulfilled order count', 'count'] }.each do |field, (meaning, unit)|
            add(out, row[field], unit, row['currency'], source, period, meaning, "lines.#{index}.#{field}")
          end
        end
        Array(data['totals_by_currency']).each_with_index do |row, index|
          add(out, row['gross_cents'], 'money', row['currency'], order_source(args['source']), period,
            'Gross sales total (paid or fulfilled orders)', "totals_by_currency.#{index}.gross_cents")
        end
        out['refunded_orders'] = RefundEvidence.build(data, period, args['source']) if data.key?('refunded_orders_by_source')
        out['daily'] = daily_evidence(data['daily'], period, order_source(args['source'])) if args['include_daily'] == true
        out['gaps'] << 'Product breakdowns are not certified by this contract.' if data['top_products'].present?
      when 'period_review'
        period = window(data, args['from'], args['to'])
        if args['from'].blank? && args['to'].blank?
          preset = TimeRangePicker.preset(args['period'].presence || 'yesterday', Date.current)
          raise ArgumentError unless preset && period == window({ 'from' => preset.from.iso8601, 'to' => [preset.to, Date.current].min.iso8601 })
        end
        Array(data['sales']).each_with_index do |row, index|
          add(out, row['gross_cents'], 'money', row['currency'], ORDER_SOURCE, period, 'Gross sales (paid or fulfilled orders)', "sales.#{index}.gross_cents")
        end
        if data['compared_with'].is_a?(Hash) && data['previous_sales'].is_a?(Array) && data['change'].is_a?(Array)
          key = args['from'].present? || args['to'].present? ? nil : (args['period'].presence || 'yesterday')
          previous = Metrics::Window.new(from: Date.iso8601(period['from']), to: Date.iso8601(period['to']), label: '', key: key).previous
          old = window(data['compared_with'], previous.from.iso8601, previous.to.iso8601)
          data['previous_sales'].each_with_index do |row, index|
            add(out, row['gross_cents'], 'money', row['currency'], ORDER_SOURCE, old, 'Gross sales (paid or fulfilled orders)', "previous_sales.#{index}.gross_cents")
          end
          data['change'].each_with_index do |row, index|
            currency = row['currency']
            raise ArgumentError unless Array(data['sales']).any? { |sale| sale['currency'] == currency && sale['gross_cents'].is_a?(Integer) } &&
              data['previous_sales'].any? { |sale| sale['currency'] == currency && sale['gross_cents'].is_a?(Integer) && sale['gross_cents'].positive? }

            add(out, row['gross_change_percent'], 'percent', currency, ORDER_SOURCE, period,
              "Gross sales: change versus #{old['from']} to #{old['to']} (not percentage points)", "change.#{index}.gross_change_percent")
          end
          missing = Array(data['sales']).filter_map { |row| row['currency'] if CURRENCIES.include?(row['currency']) && data['previous_sales'].none? { |sale| sale['currency'] == row['currency'] } }.uniq
          if missing.any?
            out['gaps'] << "No comparison sales rows were returned for #{missing.join(', ')} in #{old['from']} to #{old['to']}; missing rows do not prove zero."
          end
        else
          out['gaps'] << 'Comparison figures were not available in the period review.'
        end
        out['gaps'] << 'Expenses without explicit currency and other review sections are not certified by this contract; ' \
                       'profit cannot be established from this evidence.'
      when 'sales_tax_report'
        period = window(data, args['from'] || Date.current.beginning_of_month.iso8601, args['to'] || Date.current.iso8601)
        allowed = (args['sources'].presence || SalesTaxReport::SOURCES.keys).map { |key| SalesTaxReport::SOURCES.fetch(key) }
        Array(data['lines']).each_with_index do |row, index|
          raise ArgumentError unless allowed.include?(row['source']) && row['store'].present?

          store = row['store'].to_s
          if store.length > 256 || AskRupert::Redactor.personal(store) != store
            out['gaps'] << 'A store identity could not be displayed safely; its figures were omitted.'
            next
          end
          source = "#{row['source']} / store #{store.inspect}; separate source, never added across sources"
          { 'tax_collected' => 'Reported tax collected', 'tax_refunded' => 'Reported tax refunded', 'net_tax' => 'Net reported tax', 'estimated_tax' => 'Estimated tax (not reported tax)' }.each do |field, meaning|
            add(out, row[field], 'money', row['currency'], source, period, meaning, "lines.#{index}.#{field}")
          end
        end
      when 'daily_close'
        first = args['from'] || Date.current.iso8601
        period = window(data, first, args['to'] || first)
        if data['stores'].is_a?(Array) && data['stores'].empty?
          out['gaps'] << "No store register records were returned for #{period['from']} to #{period['to']} and the selected filter; " \
                         'this does not prove zero sales.'
        end
        rows = Array(data['stores']).each_with_index.filter_map do |row, index|
          store = row['store'].to_s
          if store.blank? || store.length > 120 || AskRupert::Redactor.personal(store) != store
            out['gaps'] << 'A store name could not be displayed safely; its figures were omitted.'
            next
          end
          Array(row['notes']).each { |note| out['gaps'] << "#{store}: #{AskRupert::Redactor.personal(note.to_s).first(240)}" }
          [row, index, "#{store}; daily-close row, kept separate from other rows and not added to canonical orders"]
        end
        # Most useful first, so a long answer drops tips and refunds before net sales.
        DAILY_CLOSE.each do |field, meaning|
          rows.each { |row, index, source| add(out, row[field], 'money', row['currency'], source, period, meaning, "stores.#{index}.#{field}") }
        end
      when 'time_keeping_report'
        period = window(data, args['from'] || Date.current.beginning_of_month.iso8601, args['to'] || Date.current.end_of_month.iso8601)
        totals = data.fetch('totals')
        scope = data.fetch('scope')
        raise ArgumentError unless %w[all\ staff own\ hours\ only].include?(scope)
        scope = 'selected employee' if scope == 'all staff' && args['employee_id'].present?

        hours = %w[scheduled worked ctrax].to_h do |key|
          value = totals[key]
          raise ArgumentError unless value.is_a?(Numeric) && BigDecimal(value.to_s).finite? && value >= 0

          [key, BigDecimal(value.to_s).to_s('F')]
        end
        timekeeping = { 'scope' => scope, 'period' => period, 'hours' => hours }
        timekeeping['id'] = Digest::SHA256.hexdigest(JSON.generate(timekeeping)).first(16)
        out['timekeeping'] = timekeeping
        sales = data['sales_same_days']
        begin
          raise ArgumentError unless sales.is_a?(Hash) && sales['available'] == true && window(sales) == period

          metric_rows(out, sales['gross_sales_by_currency'], 'gross_sales', ORDER_SOURCE, period, 'sales_same_days.gross_sales_by_currency')
        rescue ArgumentError, KeyError, TypeError, Date::Error
          out['gaps'] << 'Sales for these days are unavailable or have a mismatched period.'
        end
      when 'business_pulse'
        period = window({ 'from' => data['date'], 'to' => data['date'] }, Date.current.iso8601, Date.current.iso8601)
        metric_rows(out, data.dig('sales', 'gross_sales_by_currency'), 'gross_sales', ORDER_SOURCE, period, 'sales.gross_sales_by_currency')
        if data.dig('sales', 'gross_sales_by_currency').is_a?(Array) && data.dig('sales', 'gross_sales_by_currency').empty?
          out['gaps'] << 'No paid or fulfilled order sales rows were returned for today; missing records do not prove zero sales.'
        end
        pulse = { 'date' => period['from'], 'sections' => {} }
        { 'alerts' => 'Open alerts', 'sync' => 'Failing syncs', 'overdue_tasks' => 'Overdue tasks' }.each do |key, label|
          section = data[key]
          if section.is_a?(Hash) && section['available'] == true && section['count'].is_a?(Integer) && section['count'] >= 0
            pulse['sections'][label] = section['count']
          else
            pulse['sections'][label] = nil
          end
        end
        queues = data.dig('waiting', 'queues')
        if queues.is_a?(Array) && queues.all? { |queue| queue.is_a?(Hash) && queue['name'].is_a?(String) && queue['count'].is_a?(Integer) && queue['count'] >= 0 }
          pulse['queues'] = queues.first(10).map { |queue| { 'name' => AskRupert::Redactor.personal(queue['name']).gsub(/[\r\n\[\]<>`]/, ' ').squish.first(100), 'count' => queue['count'] } }
          pulse['queues_omitted'] = queues.size > 10
        end
        pulse['id'] = Digest::SHA256.hexdigest(JSON.generate(pulse)).first(16)
        out['pulse'] = pulse
      when 'purchase_orders'
        out['purchasing'] = PurchasingEvidence.build(data, args)
      when 'order_queues'
        out['queue_summary'] = QueueEvidence.build(data)
      else
        out['gaps'] << 'This financial tool does not yet provide a certified evidence contract.'
      end
      if out['facts'].empty? && !out['purchasing'] && !out['queue_summary']
        out['gaps'] << 'No complete financial facts were returned; missing data does not prove zero.'
      end
      out['gaps'].uniq!
      if out['facts'].size > 12
        out['facts'] = out['facts'].first(12)
        out['gaps'] |= ['Some facts were omitted to fit the response budget. Narrow the question for remaining figures.']
      end
      while JSON.generate(out).length > 5_500 && out['facts'].any?
        out['facts'].pop
        out['gaps'] |= ['Some facts were omitted to fit the response budget. Narrow the question for remaining figures.']
      end
      if JSON.generate(out).length > 5_500
        out = out.slice('version', 'tool', 'tenant_id', 'invocation').merge('facts' => [],
          'gaps' => ['Financial evidence exceeded the response budget; narrow the question and try again.'])
      end
      out['gaps'].uniq!
      out
    rescue ArgumentError, KeyError, TypeError, Date::Error
      { 'version' => VERSION, 'tool' => tool, 'tenant_id' => tenant_id, 'invocation' => invocation, 'facts' => [],
        'gaps' => ['Financial evidence has incomplete or inconsistent source, period, currency or meaning; no figures can be certified.'] }
    end

    def daily_evidence(rows, period, source)
      raise ArgumentError unless rows.is_a?(Array)

      checked = rows.map do |row|
        date = Date.iso8601(row.fetch('date'))
        raise ArgumentError unless date.between?(Date.iso8601(period['from']), Date.iso8601(period['to']))
        raise ArgumentError unless CURRENCIES.include?(row['currency']) && row['orders'].is_a?(Integer) && row['orders'] >= 0
        raise ArgumentError unless row['gross_cents'].nil? || row['gross_cents'].is_a?(Integer)
        raise ArgumentError if row['orders'].zero? && row['gross_cents'].present? && row['gross_cents'] != 0

        result = row.slice('date', 'currency', 'orders', 'gross_cents')
        # The tool emits a placeholder zero for days with no recorded orders.
        # Do not expose that placeholder to a model as an observed sales value.
        result['gross_cents'] = nil if row['orders'].zero?
        result
      end
      daily = { 'period' => period, 'source' => source, 'rows' => checked.first(30), 'omitted' => checked.size > 30 }
      daily['id'] = Digest::SHA256.hexdigest(JSON.generate(daily)).first(16)
      daily
    end

    def window(data, expected_from = nil, expected_to = nil)
      first = Date.iso8601(data.fetch('from'))
      last = Date.iso8601(data.fetch('to'))
      raise ArgumentError if last < first || (expected_from && first.iso8601 != expected_from) || (expected_to && last.iso8601 != expected_to)

      { 'from' => first.iso8601, 'to' => last.iso8601 }
    end

    def order_source(source)
      return ORDER_SOURCE if source.blank?
      raise ArgumentError unless Metrics::SOURCES.include?(source)

      "#{source} canonical orders (paid or fulfilled)"
    end

    def metric_rows(out, rows, name, source, period, path)
      meaning, unit = MEANINGS.fetch(name)
      Array(rows).each_with_index do |row, index|
        if name == 'refund_rate'
          add(out, row['value'], unit, row['currency'], source, period, meaning, "#{path}.#{index}.value")
          add(out, row['refunded_cents'], 'money', row['currency'], source, period, 'Recorded refund transaction amount', "#{path}.#{index}.refunded_cents") if row.key?('refunded_cents')
          add(out, row['refunds'], 'count', row['currency'], source, period, 'Recorded refund transaction count', "#{path}.#{index}.refunds") if row.key?('refunds')
          out['gaps'] << 'Refund transactions are counted by refund date; the associated sales may be from an earlier period.'
          next
        end
        if name == 'expenses_by_category'
          add(out, row['value'], unit, row['currency'], source, period, meaning, "#{path}.#{index}.value")
          Array(row['categories']).each_with_index do |category, category_index|
            label = category['name'].to_s
            if label.blank? || label.length > 120 || label.match?(/[\r\n\x00-\x1f]/) || AskRupert::Redactor.personal(label) != label
              out['gaps'] << 'An expense category name could not be displayed safely; its amount was omitted.'
              next
            end
            add(out, category['amount_cents'], 'money', row['currency'], source, period, "Expense category: #{label}",
              "#{path}.#{index}.categories.#{category_index}.amount_cents")
          end
          next
        end
        if name == 'top_products'
          products = Array(row['products'])
          if products.size < 10 && CURRENCIES.include?(row['currency'])
            out['gaps'] << "#{products.size} #{'product'.pluralize(products.size)} with recorded revenue in #{row['currency']} for this period."
          end
          products.each_with_index do |product, product_index|
            label = product['name'].to_s
            if label.blank? || label.length > 120 || label.match?(/[\r\n\x00-\x1f]/) || AskRupert::Redactor.personal(label) != label
              out['gaps'] << 'A product name could not be displayed safely; its revenue was omitted.'
              next
            end
            add(out, product['revenue_cents'], 'money', row['currency'], source, period, "Product revenue: #{label}",
              "#{path}.#{index}.products.#{product_index}.revenue_cents")
            if product.key?('share_percent')
              add(out, product['share_percent'], 'percent', row['currency'], source, period, "Share of product revenue: #{label}",
                "#{path}.#{index}.products.#{product_index}.share_percent")
            end
          end
          out['gaps'] << 'Product ranking covers at most ten products per currency.'
          next
        end
        if %w[best_day worst_day].include?(name)
          if row['value'].blank?
            out['gaps'] << 'Sales day is unavailable; missing data does not prove zero.'
            next
          end
          date = Date.iso8601(row['value'])
          raise ArgumentError unless date.between?(Date.iso8601(period['from']), Date.iso8601(period['to']))

          add(out, row['gross_cents'], 'money', row['currency'], source, period, "#{meaning}: #{date.iso8601}", "#{path}.#{index}.gross_cents")
          out['gaps'] << 'Only days with recorded orders are considered; days without recorded orders are not zero-sales days.'
          next
        end
        if %w[tax_collected effective_tax_rate].include?(name)
          field = name == 'tax_collected' ? 'tax_cents' : 'effective_rate_percent'
          add(out, row['value'], unit, row['currency'], source, period, meaning, "#{path}.#{index}.value")
          Array(row['sources']).each_with_index do |part, part_index|
            add(out, part[field], unit, row['currency'], order_source(part.fetch('source')), period, meaning,
              "#{path}.#{index}.sources.#{part_index}.#{field}")
          end
          next
        end
        if name == 'sales_by_source'
          source_leader(out, row, period) if source == ORDER_SOURCE
          if source == ORDER_SOURCE
            add(out, row['gross_cents'], 'money', row['currency'], source, period, 'Gross sales total (paid or fulfilled orders)', "#{path}.#{index}.gross_cents")
          end
          Array(row['sources']).each_with_index do |part, part_index|
            part_source = order_source(part.fetch('source'))
            add(out, part['gross_cents'], 'money', row['currency'], part_source, period, 'Gross sales (paid or fulfilled orders)', "#{path}.#{index}.sources.#{part_index}.gross_cents")
            add(out, part['share_percent'], 'percent', row['currency'], part_source, period, 'Share of gross sales in this currency', "#{path}.#{index}.sources.#{part_index}.share_percent")
          end
          next
        end
        add(out, row['value'], unit, row['currency'], source, period, meaning, "#{path}.#{index}.value")
      end
    end

    # Only rank a complete set of source amounts within the same currency.
    # Keep sync status separate from proof of complete sales coverage.
    def source_leader(out, row, period)
      parts = row['sources']
      return unless CURRENCIES.include?(row['currency']) && parts.is_a?(Array) && parts.any?
      return unless parts.all? { |part| part.is_a?(Hash) && Metrics::SOURCES.include?(part['source']) && part['gross_cents'].is_a?(Integer) }
      return unless row['gross_cents'].is_a?(Integer) && parts.sum { |part| part['gross_cents'] } == row['gross_cents']

      highest = parts.map { |part| part['gross_cents'] }.max
      leaders = parts.select { |part| part['gross_cents'] == highest }.map do |part|
        status = part.dig('sync', 'status') if part['sync'].is_a?(Hash)
        status = 'unknown' unless %w[ok success failed error running unknown not_available].include?(status)
        "#{part['source']} (sync: #{status.tr('_', ' ')})"
      end
      out['gaps'] << "Highest recorded source sales in #{row['currency']} for #{period['from']} to #{period['to']}: #{leaders.join(', ')}. " \
                     'Sync status alone does not establish complete coverage.'
    end

    def add(out, value, unit, currency, source, period, meaning, path)
      unless value.is_a?(Numeric) && CURRENCIES.include?(currency)
        out['gaps'] << 'A figure with a missing value or currency was omitted; unknown is not zero.'
        return
      end
      raise ArgumentError if unit == 'money' && !value.is_a?(Integer)
      raise ArgumentError if unit == 'count' && (!value.is_a?(Integer) || value.negative?)

      decimal = BigDecimal(value.to_s)
      raise ArgumentError unless decimal.finite?

      decimal /= 100 if unit == 'money'
      fact = { 'meaning' => meaning, 'unit' => unit, 'value' => decimal.to_s('F'), 'currency' => currency,
               'source' => source, 'period' => period, 'timezone' => Time.zone.name, 'field' => path, 'tool' => out['tool'], 'tenant_id' => out['tenant_id'], 'invocation' => out['invocation'] }
      fact['id'] = Digest::SHA256.hexdigest(JSON.generate(fact)).first(16)
      out['facts'] << fact
    end

    def decode(text, tenant_id, tool: nil, invocation: nil)
      data = JSON.parse(text)
      return unless data.is_a?(Hash) && data['version'] == VERSION && data['tenant_id'] == tenant_id && data['facts'].is_a?(Array) && data['gaps'].is_a?(Array)
      return if (tool && data['tool'] != tool) || (invocation && data['invocation'] != invocation)
      return unless data['facts'].all? do |fact|
        fact.is_a?(Hash) && fact['tenant_id'] == tenant_id && fact['tool'] == data['tool'] && fact['invocation'] == data['invocation'] &&
          fact['id'] == Digest::SHA256.hexdigest(JSON.generate(fact.except('id'))).first(16)
      end
      if data['timekeeping']
        context = data['timekeeping']
        return unless data['tool'] == 'time_keeping_report' && context.is_a?(Hash) &&
          context['id'] == Digest::SHA256.hexdigest(JSON.generate(context.except('id'))).first(16)
      end
      if data['refunded_orders']
        context = data['refunded_orders']
        return unless data['tool'] == 'sales_summary' && context.is_a?(Hash) &&
          context['id'] == Digest::SHA256.hexdigest(JSON.generate(context.except('id'))).first(16)
      end
      if data['pulse']
        context = data['pulse']
        return unless data['tool'] == 'business_pulse' && context.is_a?(Hash) &&
          context['id'] == Digest::SHA256.hexdigest(JSON.generate(context.except('id'))).first(16)
      end
      if data['daily']
        context = data['daily']
        return unless data['tool'] == 'sales_summary' && context.is_a?(Hash) &&
          context['id'] == Digest::SHA256.hexdigest(JSON.generate(context.except('id'))).first(16)
      end
      if data['purchasing']
        context = data['purchasing']
        return unless data['tool'] == 'purchase_orders' && context.is_a?(Hash) &&
          context['id'] == Digest::SHA256.hexdigest(JSON.generate(context.except('id'))).first(16)
      end
      if data['queue_summary']
        context = data['queue_summary']
        return unless data['tool'] == 'order_queues' && context.is_a?(Hash) &&
          context['id'] == Digest::SHA256.hexdigest(JSON.generate(context.except('id'))).first(16)
      end

      data
    rescue JSON::ParserError, TypeError
      nil
    end

    # The bot's own wording, kept only when every figure in it is one of the checked facts: each money amount (to
    # the cent, in a currency the facts have), percentage and order count; no profit/margin wording; tax, refunds,
    # expenses or averages only when a fact means that; and period words (today, last month...) only when a fact
    # covers exactly that period. Then Ruby adds what the figures are (meaning, source, period) and any gaps.
    # Returns nil when the prose does not pass, so the caller renders the facts instead.
    RELABEL = /\b(?:profits?|margins?|net income|earnings|take[- ]home|cash flow|bottom line)\b/i
    CONCEPTS = { /\btax(?:es)?\b/i => /tax/i, /\brefund/i => /refund/i, /\bexpense/i => /expense/i, /\baverage\b/i => /average/i,
                 /\bshare\b/i => /share/i }.freeze
    PERIOD_WORDS = { 'today' => 'today', 'yesterday' => 'yesterday', 'this week' => 'this_week', 'last week' => 'last_week',
                     'this month' => 'this_month', 'last month' => 'last_month', 'this quarter' => 'this_quarter',
                     'last quarter' => 'last_quarter', 'this year' => 'year_to_date', 'last year' => 'last_year' }.freeze
    CODED_AMOUNT = /(?<![\w.])-?\d[\d,]*\.\d{2}\s?(?<code>[A-Z]{3})\b/
    ORDER_COUNT = /(?<![\w.$])(?<count>\d[\d,]*)\s+(?:(?:paid|fulfilled|online|shopify|square)\s+)*orders?\b/i

    def checked_prose(text, evidence, today: Date.current)
      # Numeric checks cannot establish whether narrative claims that a
      # comparison was present or absent agree with the period-review result.
      return nil if evidence.any? { |item| item['tool'] == 'period_review' }

      # Hours need their own semantic validation; render them deterministically
      # instead of accepting unchecked prose next to certified financial facts.
      return nil if evidence.any? { |item| item['timekeeping'] || item['pulse'] || item['daily'] || item['purchasing'] || item['queue_summary'] }
      return nil if evidence.any? { |item| item['gaps'].any? { |gap| gap.start_with?('Highest recorded source sales') } }

      facts = evidence.flat_map { |item| item['facts'] }
      # Numeric matching cannot verify that a model kept the product,
      # category, or date attached to the value. Render those facts directly.
      return nil if facts.any? { |fact| fact['meaning'].to_s.match?(/\A(?:Product revenue:|Share of product revenue:|Expense category:|Highest recorded sales day:|Lowest recorded sales day:)/) }

      prose = text.to_s.strip
      return nil if facts.empty? || prose.blank? || prose.match?(RELABEL)
      # NumberCheck currently extracts unsigned figures. Use deterministic
      # rendering when either side has a sign so a loss cannot become a gain.
      return nil if facts.any? { |fact| BigDecimal(fact['value']).negative? } || prose.match?(/(?:[-−]\s*\$?\s*\d|\$\s*[-−]\s*\d)/)

      # When a source is named, compare every asserted figure against that
      # source's own facts. Aggregate totals cannot prove a source attribution.
      named_sources = { 'shopify' => /\bshopify\b/i, 'square' => /\bsquare\b/i,
                        'rupert_pos' => /\brupert[ _-]+pos\b/i }.select { |_, pattern| prose.match?(pattern) }.keys
      return nil if named_sources.size > 1
      if named_sources.one?
        prefix = "#{named_sources.first} canonical orders"
        facts = facts.select { |fact| fact['source'].to_s.start_with?(prefix) }
        return nil if facts.empty?
      end

      meanings = facts.map { |fact| fact['meaning'].to_s }
      return nil if CONCEPTS.any? { |word, meaning| prose.match?(word) && meanings.none? { |known| known.match?(meaning) } }
      return nil unless periods_match?(prose, facts, today)

      currencies = facts.map { |fact| fact['currency'] }.uniq
      return nil if prose.scan(CODED_AMOUNT).flatten.any? { |code| !currencies.include?(code) }

      money = facts.select { |fact| fact['unit'] == 'money' }
      checked = 0
      NumberCheck.figures_in(prose).each do |figure|
        pool = figure.kind == :percent ? facts.select { |fact| fact['unit'] == 'percent' } : money
        pool = pool.select { |fact| fact['currency'] == 'USD' } if figure.kind == :money && figure.text.include?('$')
        return nil unless pool.any? { |fact| figure_matches?(figure, fact) }

        checked += 1
      end
      counts = facts.select { |fact| fact['unit'] == 'count' }.map { |fact| BigDecimal(fact['value']) }
      prose.scan(ORDER_COUNT).flatten.each do |count|
        return nil unless counts.include?(BigDecimal(count.delete(',')))

        checked += 1
      end
      return nil if checked.zero?

      [prose, note(facts, evidence, today)].join("\n\n")
    end

    def figure_matches?(figure, fact)
      value = BigDecimal(fact['value']).abs
      shown = BigDecimal(figure.text[/\d[\d,]*(?:\.\d+)?/].delete(','))
      return (value - shown).abs <= BigDecimal('0.5') / (10**figure.decimals) if figure.kind == :percent
      return false unless figure.decimals == 2 || (figure.decimals.zero? && value.frac.zero?)

      value == shown
    end

    def periods_match?(prose, facts, today)
      spans = facts.map { |fact| [fact.dig('period', 'from'), fact.dig('period', 'to')] }.uniq
      PERIOD_WORDS.all? do |words, key|
        next true unless prose.match?(/\b#{words}(?:'s)?\b/i)

        window = Metrics::Window.resolve(period: key, today: today)
        spans.include?([window.from.iso8601, window.to.iso8601])
      rescue ArgumentError
        false
      end
    end

    # One short line per kind of figure: what it means, where it comes from and the period, written by Ruby.
    def note(facts, evidence, today)
      lines = facts.map { |fact| [fact['meaning'], source_label(fact['source']), period_label(fact['period'], today)] }.uniq.first(3).map do |meaning, source, period|
        "✓ #{meaning} · #{source} · #{period}"
      end
      (lines + evidence.flat_map { |item| item['gaps'] }.uniq).join("\n")
    end

    def source_label(source)
      source.to_s.sub(ORDER_SOURCE, 'Shopify, Square, Rupert POS and manual orders (not C-Trax or SwipeSimple)')
    end

    def period_label(period, today)
      from = Date.iso8601(period['from'].to_s)
      to = Date.iso8601(period['to'].to_s)
      return 'today' if from == today && to == today
      return 'yesterday' if from == today - 1 && to == today - 1
      return from.strftime('%b %-d, %Y') if from == to

      from.year == to.year ? "#{from.strftime('%b %-d')} – #{to.strftime('%b %-d, %Y')}" : "#{from.strftime('%b %-d, %Y')} – #{to.strftime('%b %-d, %Y')}"
    rescue Date::Error, TypeError
      "#{period['from']} to #{period['to']}"
    end

    def render(evidence)
      # Repeated identical calls are separate audit events but should not be
      # presented to the user as separate products or financial results.
      facts = evidence.flat_map { |item| item['facts'] }.uniq do |fact|
        fact.values_at('meaning', 'unit', 'value', 'currency', 'source', 'period', 'timezone')
      end
      lines = facts.first(12).map do |fact|
        number = BigDecimal(fact.fetch('value'))
        whole, fraction = number.to_s('F').split('.')
        value = fact['unit'] == 'money' ? "#{whole}.#{fraction.to_s.ljust(2, '0')}" : number.to_s('F').delete_suffix('.0')
        value += '%' if fact['unit'] == 'percent'
        suffix = fact['unit'] == 'money' ? fact['currency'] : "(#{fact['currency']} group)"
        "- #{fact['meaning']}: #{value} #{suffix} (#{fact['source']}; #{fact.dig('period', 'from')} to #{fact.dig('period', 'to')} #{fact['timezone']})."
      end
      evidence.filter_map { |item| item['timekeeping'] }.uniq.each do |context|
        hours = context.fetch('hours')
        lines << "- Timekeeping (#{context['scope']}; #{context.dig('period', 'from')} to #{context.dig('period', 'to')}): #{hours['worked']} hours worked, #{hours['scheduled']} hours scheduled; #{hours['ctrax']} C-Trax hours observed separately, not added."
      end
      evidence.filter_map { |item| item['pulse'] }.uniq.each do |pulse|
        lines << "- Business pulse for #{pulse['date']}:"
        pulse.fetch('sections').each { |label, count| lines << "  - #{label}: #{count.nil? ? 'unavailable' : count}." }
        if pulse['queues']
          lines << (pulse['queues'].empty? ? '  - No waiting queues were reported.' : '  - Waiting queues:')
          pulse['queues'].each { |queue| lines << "    - #{queue['name']}: #{queue['count']}." }
          lines << '  - Additional queues were omitted.' if pulse['queues_omitted']
        else
          lines << '  - Waiting queues: unavailable.'
        end
      end
      evidence.filter_map { |item| item['daily'] }.uniq.each do |daily|
        lines << "- Daily sales (#{daily['source']}; #{daily.dig('period', 'from')} to #{daily.dig('period', 'to')}):"
        lines << '  - No daily sales rows were returned.' if daily['rows'].empty?
        daily['rows'].each do |row|
          if row['orders'].zero?
            lines << "  - #{row['date']} (#{row['currency']}): no paid or fulfilled orders stored."
          else
            amount = if row['gross_cents'].nil?
              "#{row['currency']} gross unavailable"
            else
              whole, fraction = (BigDecimal(row['gross_cents'].to_s) / 100).to_s('F').split('.')
              "#{whole}.#{fraction.to_s.ljust(2, '0')} #{row['currency']} gross"
            end
            lines << "  - #{row['date']}: #{amount}; #{row['orders']} recorded orders."
          end
        end
        lines << '  - Additional daily rows were omitted; narrow the date range.' if daily['omitted']
        lines << '  - Missing stored orders do not prove there were no sales.'
      end
      evidence.filter_map { |item| item['purchasing'] }.uniq.each { |context| lines << PurchasingEvidence.render(context) }
      evidence.filter_map { |item| item['queue_summary'] }.uniq.each { |context| lines << QueueEvidence.render(context) }
      lines.unshift('From Rupert’s records:') if lines.any?
      gaps = evidence.flat_map { |item| item['gaps'] }.uniq
      missing_metrics, other_gaps = gaps.partition { |gap| gap.start_with?('No metric rows were returned for the requested period') }
      lines = missing_metrics + lines
      if facts.empty? && evidence.none? { |item| item['purchasing'] || item['queue_summary'] }
        lines << 'I could not verify financial figures for this request.'
      end
      lines << 'Additional verified facts were omitted. Narrow the question for the remaining figures.' if facts.size > 12
      lines.concat(other_gaps)
      lines.join("\n")
    end
  end
end
