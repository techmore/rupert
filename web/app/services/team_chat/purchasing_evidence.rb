# frozen_string_literal: true

module TeamChat
  # A bounded, authorized purchase-order page. Keep filters, currencies and
  # individual order amounts; never infer a total across orders or vendors.
  module PurchasingEvidence
    FILTERS = %w[status vendor query from to overdue_only page per_page].freeze
    STATUSES = %w[draft ordered received cancelled].freeze

    module_function

    def build(data, args)
      raise ArgumentError unless %w[orders vendors].include?(data['view']) && data['rows'].is_a?(Array) && data['meta'].is_a?(Hash)
      return build_vendors(data, args) if data['view'] == 'vendors'

      rows = data['rows'].first(8).map { |row| order(row) }
      status = args['status'] == 'open' ? 'ordered' : args['status']
      raise ArgumentError if status.present? && status != 'all' && rows.any? { |row| row['status'] != status }

      filters = args.slice(*FILTERS).transform_values { |value| label(value) }
      context = { 'filters' => filters, 'rows' => rows,
                  'more' => data['rows'].size > 8 || data['meta']['has_more'] != false }
      context['id'] = Digest::SHA256.hexdigest(JSON.generate(context)).first(16)
      context
    end

    def build_vendors(data, args)
      from = Date.iso8601(data.fetch('from'))
      to = Date.iso8601(data.fetch('to'))
      raise ArgumentError if to < from || (args['from'].present? && args['from'] != from.iso8601) || (args['to'].present? && args['to'] != to.iso8601)
      raise ArgumentError unless FinancialEvidence::CURRENCIES.include?(data['currency'])

      rows = data['rows'].first(8).map { |row| vendor(row) }
      context = { 'kind' => 'vendors', 'filters' => args.slice('vendor', 'page', 'per_page').transform_values { |value| label(value) },
                  'period' => { 'from' => from.iso8601, 'to' => to.iso8601 }, 'currency' => data['currency'], 'rows' => rows,
                  'more' => data['rows'].size > 8 || data['meta']['has_more'] != false }
      context['id'] = Digest::SHA256.hexdigest(JSON.generate(context)).first(16)
      context
    end

    def vendor(row)
      raise ArgumentError unless row.is_a?(Hash)

      result = { 'name' => label(row['name'].presence || 'Unnamed vendor') }
      %w[spend_cents open_due_cents paid_in_window_cents].each { |key| result[key] = row[key] if row[key].is_a?(Integer) }
      %w[open_orders overdue_orders lead_time_orders].each do |key|
        result[key] = row[key] if row[key].is_a?(Integer) && row[key] >= 0
      end
      lead = row['average_lead_days']
      if lead.is_a?(Numeric) && lead.finite? && lead >= 0 && result['lead_time_orders'].to_i.positive?
        result['average_lead_days'] = lead
      end
      result
    end

    def order(row)
      raise ArgumentError unless row.is_a?(Hash) && STATUSES.include?(row['status'])

      result = { 'number' => label(row['order_number'].presence || row['id'].presence || 'unknown'),
                 'vendor' => label(row['vendor'].presence || 'unknown vendor'), 'status' => row['status'] }
      result['expected_date'] = row['expected_date'] if row['expected_date'].to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      if FinancialEvidence::CURRENCIES.include?(row['currency'])
        result['currency'] = row['currency']
        %w[total_cents due_cents].each { |key| result[key] = row[key] if row[key].is_a?(Integer) }
      end
      items = row['lines'].is_a?(Array) ? row['lines'].first(2).filter_map { |line| order_line(line) } : []
      result['lines'] = items
      result['lines_omitted'] = (row['line_count'].is_a?(Integer) && row['line_count'] > items.size) ||
                                (row['lines'].is_a?(Array) && row['lines'].size > items.size)
      result
    end

    def order_line(line)
      return unless line.is_a?(Hash)

      result = { 'name' => label(line['name'].presence || 'Unnamed item').first(60) }
      result['sku'] = label(line['sku']).first(60) if line['sku'].present?
      %w[quantity received_quantity].each do |key|
        value = line[key]
        result[key] = value if value.is_a?(Numeric) && value.finite? && value >= 0
      end
      result
    end

    def render(context)
      return render_vendors(context) if context['kind'] == 'vendors'

      filters = context['filters'].map { |key, value| "#{key.tr('_', ' ')}: #{value}" }.join(', ')
      lines = ["Purchase orders (#{filters.presence || 'all statuses'}):"]
      lines << 'No purchase orders were returned on this page.' if context['rows'].empty?
      context['rows'].each do |row|
        line = "- #{row['number']} — #{row['vendor']} (#{row['status']})"
        line += "; expected #{row['expected_date']}" if row['expected_date']
        %w[total_cents due_cents].each do |key|
          next unless row[key].is_a?(Integer) && row['currency']

          whole, fraction = (BigDecimal(row[key].to_s) / 100).to_s('F').split('.')
          line += "; #{key == 'total_cents' ? 'order total' : 'still due'} #{whole}.#{fraction.to_s.ljust(2, '0')} #{row['currency']}"
        end
        lines << "#{line}."
        Array(row['lines']).each do |item|
          detail = "  - #{item['name']}"
          detail += " (SKU #{item['sku']})" if item['sku'].present?
          detail += "; #{item['quantity']} ordered" if item.key?('quantity')
          detail += "; #{item['received_quantity']} received" if item.key?('received_quantity')
          lines << "#{detail}."
        end
        lines << '  - Additional line items were omitted or unavailable.' if row['lines_omitted']
      end
      lines << 'More orders may be available; narrow the filters or inspect the next page.' if context['more']
      lines.join("\n")
    end

    def render_vendors(context)
      filters = context['filters'].map { |key, value| "#{key.tr('_', ' ')}: #{value}" }.join(', ')
      lines = ["Vendors (#{filters.presence || 'all vendors'}; PO spend and payments #{context.dig('period', 'from')} to #{context.dig('period', 'to')}):"]
      lines << 'No vendors were returned on this page.' if context['rows'].empty?
      context['rows'].each do |row|
        line = "- #{row['name']}"
        { 'spend_cents' => 'placed PO value, not payments', 'open_due_cents' => 'currently due on open POs',
          'paid_in_window_cents' => 'recorded vendor payments in the period' }.each do |key, meaning|
          next unless row[key].is_a?(Integer)

          whole, fraction = (BigDecimal(row[key].to_s) / 100).to_s('F').split('.')
          line += "; #{meaning}: #{whole}.#{fraction.to_s.ljust(2, '0')} #{context['currency']}"
        end
        line += "; #{row['open_orders']} open orders" if row.key?('open_orders')
        line += "; average lead #{row['average_lead_days']} days across received orders" if row.key?('average_lead_days')
        lines << "#{line}."
      end
      lines << 'More vendors may be available; narrow the filters or inspect the next page.' if context['more']
      lines << 'Vendor payment data is unavailable where it was not returned.'
      lines.join("\n")
    end

    def label(value)
      AskRupert::Redactor.personal(value.to_s).gsub(/[\r\n\[\]<>`]/, ' ').squish.first(100)
    end
  end
end
