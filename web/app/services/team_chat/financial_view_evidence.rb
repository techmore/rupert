# frozen_string_literal: true

require 'bigdecimal'
require 'date'

module TeamChat
  # A numerical match alone cannot attach a figure to its source or date.
  # Admit structured source, daily, product and expense-category views whose
  # rows can be checked against authorized evidence. Other financial views
  # remain unavailable until they have a similarly scoped contract.
  module FinancialViewEvidence
    module_function

    FINANCIAL = /\b(?:sales|revenue|gross|income|profit|margin|expense|expenses|tax|refund|cash|money|financial|amount|cost|price)\b/i

    # Build a useful fallback from typed source facts if a small model could
    # not produce a valid view. Never infer missing source/currency values.
    def source_fallback(evidence, question:)
      text = question.to_s.downcase
      return unless text.match?(/\b(?:chart|graph|plot)\b/) && text.match?(/\b(?:sales|revenue)\b/) && text.match?(/\bby source\b/)
      return if text.match?(/\b(?:no|without|omit|skip)\s+(?:(?:a|the|any)\s+)?(?:chart|graph|plot)\b/)
      return if text.match?(/\b(?:net|refund|tax|profit|compare|versus|except|exclude|only)\b/)
      return if text.match?(/\b(?:shopify|square|rupert[ _-]?pos|manual|ctrax|swipesimple)\b/) || text.match?(/\b\d{4}-\d{2}-\d{2}\b/)

      periods = { 'last week' => 'last_week', 'last month' => 'last_month', 'yesterday' => 'yesterday' }.select { |phrase, _| text.include?(phrase) }
      return unless periods.one?

      window = Metrics::Window.resolve(period: periods.values.first)
      period = { 'from' => window.from.iso8601, 'to' => window.to.iso8601 }
      facts = evidence.flat_map { |item| Array(item['facts']) }.select do |fact|
        fact['period'] == period && fact['meaning'] == 'Gross sales (paid or fulfilled orders)' && fact['unit'] == 'money'
      end
      cells = {}
      facts.each do |fact|
        source = Metrics::SOURCES.find { |name| fact['source'].to_s.start_with?("#{name} canonical orders") }
        next unless source && FinancialEvidence::CURRENCIES.include?(fact['currency'])

        key = [source, fact['currency']]
        value = number(fact['value'])
        return unless value && (!cells.key?(key) || cells[key] == value)

        cells[key] = value
      end
      return if cells.empty?

      currencies = cells.keys.map(&:last).uniq.sort
      return if currencies.size + 1 > Views::MAX_COLUMNS

      rows = cells.keys.map(&:first).uniq.sort.map do |source|
        [source] + currencies.map { |currency| cells[[source, currency]]&.to_s('F') }
      end
      args = { 'kind' => 'bar_chart', 'title' => "Sales by source #{period['from']} to #{period['to']}",
               'columns' => ['Source'] + currencies.map { |currency| "Gross sales #{currency}" }, 'rows' => rows }
      view = Views.build(args, known_text: JSON.generate(evidence))
      return if check(view, evidence, question: question)

      with_safe_caption(view, evidence, question: question)
    rescue ArgumentError, TypeError
      nil
    end

    def daily_period_for(question)
      text = question.to_s.downcase
      return unless text.match?(/\b(?:chart|graph|plot)\b/) && text.match?(/\b(?:sales|revenue)\b/) && text.match?(/\btrend\b/)
      return if text.match?(/\b(?:no|without|omit|skip)\s+(?:(?:a|the|any)\s+)?(?:chart|graph|plot)\b/)
      return if text.match?(/\b(?:net|refund|tax|profit|compare|versus|except|exclude|only|shopify|square|rupert[ _-]?pos|manual|ctrax|swipesimple)\b/)
      return if text.match?(/\b\d{4}-\d{2}-\d{2}\b/) || text.match?(/\b(?:no|without|omit|skip)\s+(?:daily|day[- ]by[- ]day|per[- ]day)\b/)

      periods = { 'last week' => 'last_week', 'last month' => 'last_month' }.select { |phrase, _| text.include?(phrase) }
      return unless periods.one?

      window = Metrics::Window.resolve(period: periods.values.first)
      { 'from' => window.from.iso8601, 'to' => window.to.iso8601 }
    rescue ArgumentError, TypeError
      nil
    end

    def daily_fallback(evidence, question:)
      period = daily_period_for(question)
      return unless period

      contexts = evidence.filter_map { |item| item['daily'] }.select { |daily| daily['period'] == period && daily['source'] == FinancialEvidence::ORDER_SOURCE && !daily['omitted'] }
      return unless contexts.one?

      cells = {}
      contexts.first.fetch('rows').each do |row|
        key = [row.fetch('date'), row.fetch('currency')]
        return if cells.key?(key)

        cents = row['gross_cents']
        cells[key] = cents.nil? ? nil : (BigDecimal(cents.to_s) / 100).to_s('F')
      end
      currencies = cells.keys.map(&:last).uniq.sort
      return if cells.empty? || currencies.size + 1 > Views::MAX_COLUMNS
      dates = (Date.iso8601(period['from'])..Date.iso8601(period['to'])).map(&:iso8601)
      return unless currencies.all? { |currency| dates.all? { |date| cells.key?([date, currency]) } }

      rows = dates.map { |date| [date] + currencies.map { |currency| cells[[date, currency]] } }
      args = { 'kind' => 'line_chart', 'title' => "Sales by day #{period['from']} to #{period['to']}",
               'columns' => ['Date'] + currencies.map { |currency| "Gross sales #{currency}" }, 'rows' => rows }
      view = Views.build(args, known_text: JSON.generate(evidence))
      return if check(view, evidence, question: question)

      with_safe_caption(view, evidence, question: question)
    rescue ArgumentError, KeyError, TypeError
      nil
    end

    def check(view, evidence, question:)
      if view['kind'] == 'html' && [question, view['title'], view['note'], view['html']].compact.join(' ').match?(FINANCIAL)
        return 'Financial views must use a structured, verifiable table or chart.'
      end
      return nil unless %w[table bar_chart line_chart].include?(view['kind'])

      description = description_for(view)
      return nil unless financial?(view, question: question)

      text = "#{question} #{description}".tr('_', ' ')
      if description.match?(/\b(?:profit|margin|net|cash|income|tax|refund|payment)\b/i)
        return 'This financial meaning does not yet have a verified view contract.'
      end

      columns = Array(view['columns']).map { |column| column.to_s.tr('_', ' ') }
      rows = Array(view['rows'])
      return 'Financial views need recorded evidence and numeric rows.' if evidence.empty? || rows.none? { |row| Array(row).drop(1).any? { |cell| number(cell) } }
      return 'Financial views need a label and at least one value column.' if columns.size < 2

      case columns.first
      when /\b(?:source|channel)\b/i then source_rows(columns, rows, evidence, text)
      when /\b(?:date|day)\b/i then daily_rows(columns, rows, evidence, text)
      when /\b(?:product|item|category)\b/i then named_rows(columns, rows, evidence, text)
      else 'Use source, date, product or category labels with recorded financial values for an adjustable view.'
      end
    rescue ArgumentError, TypeError
      'The view contains an invalid or inconsistent financial value.'
    end

    def financial?(view, question:)
      description = description_for(view)
      nonfinancial = description.match?(/\b(?:sku|stock|inventory|alerts?|tasks?|timesheets?)\b/i)
      description.match?(FINANCIAL) || (question.to_s.match?(FINANCIAL) && !nonfinancial)
    end

    def description_for(view)
      ([view['title'], view['note']] + Array(view['columns'])).compact.join(' ').tr('_', ' ')
    end

    # A model-written caption may misstate source coverage even when the rows
    # are correct. Use a neutral caption tied to the checked period.
    def with_safe_caption(view, evidence, question:)
      return view unless financial?(view, question: question)

      text = "#{question} #{description_for(view)}".tr('_', ' ')
      daily = Array(view['columns']).first.to_s.match?(/\b(?:date|day)\b/i)
      periods = evidence.flat_map do |item|
        daily ? [item.dig('daily', 'period')].compact : Array(item['facts']).filter_map { |fact| fact['period'] }
      end.select { |period| period_named?(period, text) }.uniq
      raise ArgumentError, 'The view period could not be verified.' unless periods.one?

      label = case Array(view['columns']).first.to_s
              when /\b(?:source|channel)\b/i then 'Recorded sales by source'
              when /\b(?:date|day)\b/i then 'Recorded sales by day'
              when /\bcategory\b/i then 'Recorded expense categories'
              else 'Recorded product revenue'
              end
      period = periods.first
      view.merge('title' => "#{label}: #{period['from']} to #{period['to']}",
        'note' => 'Only recorded data are shown. Missing records do not prove zero or complete coverage.')
    end

    def source_rows(columns, rows, evidence, text)
      facts = evidence.flat_map { |item| Array(item['facts']) }
      periods = facts.filter_map { |fact| fact['period'] if period_named?(fact['period'], text) }.uniq
      return 'A source chart must identify one recorded period with its start and end dates.' unless periods.one?

      seen = []
      rows.each do |row|
        label = row[0].to_s.downcase.tr('_-', ' ').squish
        source = Metrics::SOURCES.find { |name| name.tr('_', ' ') == label }
        return 'A source label could not be matched to a recorded sales source.' unless source
        return 'A source is repeated in the view.' if seen.include?(source)

        seen << source

        columns.drop(1).each_with_index do |column, offset|
          cell = row[offset + 1]
          next if cell.nil? || cell == ''

          currency = currency_for(column, text)
          value = number(cell)
          return 'A source value or its currency is unavailable.' unless currency && value

          candidates = facts.select do |fact|
            fact['currency'] == currency && fact['source'].to_s.start_with?("#{source} canonical orders") &&
              fact['period'] == periods.first && fact_matches_column?(fact, column)
          end
          return 'A chart value could not be verified for its source, currency, period and unit.' unless candidates.any? { |fact| same_value?(value, fact['value'], column) }
        end
      end
      nil
    end

    def daily_rows(columns, rows, evidence, text)
      contexts = evidence.filter_map { |item| item['daily'] }
      periods = contexts.filter_map { |context| context['period'] if period_named?(context['period'], text) }.uniq
      return 'A daily chart must identify one recorded period with its start and end dates.' unless periods.one?

      seen = []
      rows.each do |row|
        date = Date.iso8601(row[0].to_s).iso8601
        return 'A date is repeated in the view.' if seen.include?(date)

        seen << date
        columns.drop(1).each_with_index do |column, offset|
          cell = row[offset + 1]
          next if cell.nil? || cell == ''

          currency = currency_for(column, text)
          value = number(cell)
          return 'A daily value or its currency is unavailable.' unless currency && value

          matching = contexts.any? do |context|
            context['period'] == periods.first && Array(context['rows']).any? do |daily|
              daily['date'] == date && daily['currency'] == currency && daily_value_matches?(daily, column, value)
            end
          end
          return 'A chart value could not be verified for its date, currency, period and unit; missing days are not zero.' unless matching
        end
      end
      nil
    end

    def daily_value_matches?(row, column, value)
      if column.match?(/\borders?\b/i)
        row['orders'].is_a?(Integer) && value == row['orders']
      elsif column.match?(/\b(?:sales|gross|revenue)\b/i) && row['orders'].to_i.positive? && row['gross_cents'].is_a?(Integer)
        expected = BigDecimal(row['gross_cents'].to_s)
        expected /= 100 unless column.match?(/\bcents?\b/i)
        value == expected
      else
        false
      end
    end

    def named_rows(columns, rows, evidence, text)
      facts = evidence.flat_map { |item| Array(item['facts']) }
      periods = facts.filter_map { |fact| fact['period'] if period_named?(fact['period'], text) }.uniq
      return 'A financial view must identify one recorded period with its start and end dates.' unless periods.one?

      category = columns.first.match?(/\bcategory\b/i)
      seen = []
      rows.each do |row|
        label = row[0].to_s.squish
        return 'A product or category label is missing or repeated.' if label.blank? || seen.include?(label.downcase)

        seen << label.downcase
        columns.drop(1).each_with_index do |column, offset|
          cell = row[offset + 1]
          next if cell.nil? || cell == ''

          currency = currency_for(column, text)
          value = number(cell)
          return 'A product or category value or its currency is unavailable.' unless currency && value

          prefix = if category
            return 'Expense-category columns must describe recorded expenses or amounts.' unless column.match?(/\b(?:expense|expenses|cost|amount|spent)\b/i)

            'Expense category: '
          elsif column.match?(/\b(?:share|percent|percentage)\b|%/i)
            'Share of product revenue: '
          else
            return 'Product columns must describe recorded revenue or sales.' unless column.match?(/\b(?:sales|revenue|amount)\b/i)

            'Product revenue: '
          end
          unit = prefix == 'Share of product revenue: ' ? 'percent' : 'money'
          candidates = facts.select do |fact|
            fact['currency'] == currency && fact['period'] == periods.first && fact['unit'] == unit && fact['meaning'].to_s.casecmp?("#{prefix}#{label}")
          end
          return 'A value could not be verified for its product or category, currency, period and unit.' unless candidates.any? { |fact| same_value?(value, fact['value'], column) }
        end
      end
      nil
    end

    def fact_matches_column?(fact, column)
      meaning = fact['meaning'].to_s
      if column.match?(/\borders?\b/i)
        fact['unit'] == 'count' && meaning == 'Paid or fulfilled order count'
      elsif column.match?(/\b(?:share|percent|percentage)\b|%/i)
        fact['unit'] == 'percent' && meaning == 'Share of gross sales in this currency'
      else
        column.match?(/\b(?:sales|gross|revenue)\b/i) && fact['unit'] == 'money' && meaning == 'Gross sales (paid or fulfilled orders)'
      end
    end

    def same_value?(value, raw, column)
      expected = BigDecimal(raw.to_s)
      expected *= 100 if column.match?(/\bcents?\b/i)
      value == expected
    end

    def currency_for(column, text)
      currencies = FinancialEvidence::CURRENCIES
      named = column.scan(/\b[a-z]{3}\b/i).map(&:upcase).select { |word| currencies.include?(word) }.uniq
      named = text.scan(/\b[a-z]{3}\b/i).map(&:upcase).select { |word| currencies.include?(word) }.uniq if named.empty?
      named.one? ? named.first : nil
    end

    def period_named?(period, text)
      period.is_a?(Hash) && period['from'].present? && period['to'].present? && text.include?(period['from']) && text.include?(period['to'])
    end

    def number(cell)
      text = cell.to_s.strip
      return unless text.match?(/\A[-−]?\$?\d[\d,]*(?:\.\d+)?%?\z/)

      BigDecimal(text.delete('$,%').tr('−', '-'))
    end
  end
end
