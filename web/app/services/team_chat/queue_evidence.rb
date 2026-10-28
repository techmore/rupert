# frozen_string_literal: true

module TeamChat
  # Preserve authorized operational counts and a bounded set of unshipped
  # order lines without treating an alert match as an inventory observation.
  module QueueEvidence
    module_function

    RECEIPT_QUESTION = /\A(?:how many (?:expense )?receipts (?:are )?(?:awaiting|waiting for|pending) review|(?:what|which) (?:expense )?receipts (?:need|require|await|are awaiting) review|(?:any )?(?:expense )?receipts (?:to|awaiting|waiting for|pending) review)\z/i
    RECONCILIATION_QUESTION = /\A(?:(?:are there |are |any )?(?:any )?reconciliation follow[- ]?ups? (?:open|waiting|pending)|(?:any )?reconciliation follow[- ]?ups?)\z/i
    PURCHASE_ORDER_QUESTION = /\A(?:(?:are there |are |any )?(?:any )?purchase orders (?:late|overdue)|(?:any )?(?:late|overdue) purchase orders)\z/i

    # Only scope a complete request made entirely of recognized queue questions.
    # An extra clause, explanation request or qualifier keeps the general output.
    def requested_queues(question)
      text = question.to_s.sub(/\A\s*(?:@[\w.-]+\s+)+/, '').strip.sub(/[?.!]+\z/, '').strip
      parts = text.split(/\s+and\s+/i)
      names = parts.map do |part|
        case part.strip
        when RECEIPT_QUESTION then 'Expense receipts waiting for review'
        when RECONCILIATION_QUESTION then 'Reconciliation follow-ups'
        when PURCHASE_ORDER_QUESTION then 'Purchase orders awaiting delivery'
        end
      end
      names.any? && names.all? ? names.uniq : nil
    end

    # Restrict tool choice only for an explicit count or yes/no queue question.
    # Requests for which individual receipts need review may need other tools.
    def count_question?(question)
      text = question.to_s.sub(/\A\s*(?:@[\w.-]+\s+)+/, '').strip.sub(/[?.!]+\z/, '').strip
      names = requested_queues(text)
      return false unless names&.one?

      (names.first == 'Expense receipts waiting for review' && text.match?(/\Ahow many\b/i)) ||
        (names.first == 'Reconciliation follow-ups' && text.match?(/\A(?:any|are)\b/i)) ||
        (names.first == 'Purchase orders awaiting delivery' && text.match?(/\A(?:any|are)\b/i))
    end

    def render_requested(evidence, question)
      names = requested_queues(question)
      return unless names

      context = evidence.filter_map { |item| item['queue_summary'] }.find do |item|
        names.all? { |name| item['queues'].any? { |queue| queue['name'] == name } }
      end
      return unless context

      # A nonzero count cannot identify the requested receipts. Keep the
      # general answer path so other lookups can provide individual records.
      receipt = context['queues'].find { |queue| queue['name'] == 'Expense receipts waiting for review' }
      return if receipt && receipt['count'].positive? && question.to_s.match?(/\b(?:what|which)\s+(?:expense\s+)?receipts\b/i)

      lines = ['Processing queues (counts from Rupert’s records):']
      names.each do |name|
        queue = context['queues'].find { |row| row['name'] == name }
        late = if queue.key?('late')
          "; #{queue['late']} late"
        elsif name == 'Purchase orders awaiting delivery'
          '; late count unavailable'
        else
          ''
        end
        lines << "- #{queue['name']}: #{queue['count']}#{late}."
      end
      lines << 'This lookup provides counts, not individual receipt or purchase-order details.'
      lines.join("\n")
    end

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
        if queue['name'] == 'Card payments not resolved'
          lines << '  This combines register and warehouse payment attempts; it does not provide a processor-specific breakdown.'
        end
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
