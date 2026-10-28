# frozen_string_literal: true

module TeamChat
  # A bounded, authorized purchase-order page. Keep filters, currencies and
  # individual order amounts; never infer a total across orders or vendors.
  module PurchasingEvidence
    FILTERS = %w[status vendor query from to overdue_only page per_page].freeze
    STATUSES = %w[draft ordered received cancelled].freeze

    module_function

    def build(data, args)
      raise ArgumentError unless data['view'] == 'orders' && data['rows'].is_a?(Array) && data['meta'].is_a?(Hash)

      rows = data['rows'].first(8).map { |row| order(row) }
      status = args['status'] == 'open' ? 'ordered' : args['status']
      raise ArgumentError if status.present? && status != 'all' && rows.any? { |row| row['status'] != status }

      filters = args.slice(*FILTERS).transform_values { |value| label(value) }
      context = { 'filters' => filters, 'rows' => rows,
                  'more' => data['rows'].size > 8 || data['meta']['has_more'] != false }
      context['id'] = Digest::SHA256.hexdigest(JSON.generate(context)).first(16)
      context
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
      result['lines_omitted'] = row['line_count'].is_a?(Integer) && row['line_count'].positive?
      result
    end

    def render(context)
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
        line += '; line items omitted' if row['lines_omitted']
        lines << "#{line}."
      end
      lines << 'More orders may be available; narrow the filters or inspect the next page.' if context['more']
      lines.join("\n")
    end

    def label(value)
      AskRupert::Redactor.personal(value.to_s).gsub(/[\r\n\[\]<>`]/, ' ').squish.first(100)
    end
  end
end
