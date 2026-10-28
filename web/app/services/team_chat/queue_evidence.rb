# frozen_string_literal: true

module TeamChat
  # Preserve authorized operational counts and a bounded set of unshipped
  # order lines without treating an alert match as an inventory observation.
  module QueueEvidence
    module_function

    def build(data)
      raise ArgumentError unless data['queues'].is_a?(Array) && data['oldest_unshipped'].is_a?(Array)

      queues = data['queues'].first(12).map do |queue|
        raise ArgumentError unless queue.is_a?(Hash) && queue['count'].is_a?(Integer) && queue['count'] >= 0

        row = { 'name' => label(queue['name'].presence || 'Unnamed queue'), 'count' => queue['count'] }
        row['late'] = queue['late'] if queue['late'].is_a?(Integer) && queue['late'] >= 0
        row
      end
      alerts_available = data['low_stock_available'] == true
      orders = data['oldest_unshipped'].first(5).map { |order| order_row(order, alerts_available: alerts_available) }
      unshipped = queues.find { |queue| queue['name'] == 'Paid online orders not shipped' }
      context = { 'queues' => queues, 'queues_omitted' => data['queues'].size > 12,
                  'orders' => orders, 'orders_omitted' => data['oldest_unshipped'].size > 5 || (unshipped && unshipped['count'] > orders.size) }
      if alerts_available && data['waiting_on_low_stock'].is_a?(Integer) && data['waiting_on_low_stock'] >= 0
        context['waiting_on_low_stock'] = data['waiting_on_low_stock']
      end
      context['id'] = Digest::SHA256.hexdigest(JSON.generate(context)).first(16)
      context
    end

    def order_row(order, alerts_available:)
      raise ArgumentError unless order.is_a?(Hash) && order['lines'].is_a?(Array)

      lines = order['lines'].first(3).filter_map do |line|
        next unless line.is_a?(Hash)

        row = { 'name' => label(line['name'].presence || 'Unnamed item').first(60) }
        row['sku'] = label(line['sku']).first(60) if line['sku'].present?
        row['low_stock'] = line['low_stock'] if alerts_available && [true, false].include?(line['low_stock'])
        row
      end
      { 'order' => label(order['order'].presence || 'Unnamed order'), 'source' => label(order['source'].presence || 'unknown'),
        'lines' => lines, 'lines_omitted' => order['lines'].size > lines.size }
    end

    def render(context)
      lines = ['Processing queues (only queues returned by this lookup):']
      lines << 'No queue counts were returned.' if context['queues'].empty?
      context['queues'].each do |queue|
        late = queue.key?('late') ? "; #{queue['late']} late" : ''
        lines << "- #{queue['name']}: #{queue['count']}#{late}."
      end
      lines << 'Additional queue counts were omitted.' if context['queues_omitted']
      if context.key?('waiting_on_low_stock')
        lines << "- Paid unshipped orders with a line matching an open low-stock alert: #{context['waiting_on_low_stock']}."
        lines << 'An alert match or absence does not establish current inventory coverage.'
      else
        lines << 'Low-stock alert matching was unavailable.'
      end
      context['orders'].each do |order|
        lines << "- Unshipped order #{order['order']} (#{order['source']}):"
        order['lines'].each do |item|
          status = case item['low_stock']
                   when true then 'matching open low-stock alert'
                   when false then 'no matching open low-stock alert'
                   else 'alert match unknown'
                   end
          sku = item['sku'].present? ? " (SKU #{item['sku']})" : ''
          lines << "  - #{item['name']}#{sku}: #{status}."
        end
        lines << '  - Additional line items were omitted.' if order['lines_omitted']
      end
      lines << 'Additional unshipped orders were omitted.' if context['orders_omitted']
      if context['orders'].any?
        lines << 'Line items are limited by the lookup; order amounts are not included in this summary.'
      end
      lines.join("\n")
    end

    def label(value)
      AskRupert::Redactor.personal(value.to_s).gsub(/[\r\n\[\]<>`]/, ' ').squish.first(100)
    end
  end
end
