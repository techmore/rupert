# frozen_string_literal: true

module TeamChat
  # Refunded orders are counted by their order date and current status, not by
  # refund transaction date or amount. Keep that distinction visible.
  module RefundEvidence
    module_function

    def count_question?(question)
      text = question.to_s.sub(/\A\s*(?:@[\w.-]+\s+)+/, '').strip.sub(/[?.!]+\z/, '').strip
      text.match?(/\Ahow many orders (?:were|have been) refunded (?:in|over) the last 30 days(?:,? and (?:from )?which sources)?\z/i)
    end

    def build(data, period, source)
      counts = data['refunded_orders_by_source']
      return unless counts.is_a?(Hash)
      return unless counts.all? { |key, value| Mcp::Tools::SalesSummary::SOURCES.include?(key) && value.is_a?(Integer) && value.positive? && (source.blank? || key == source) }

      context = { 'period' => period, 'source' => source, 'counts' => counts.sort.to_h }
      context['id'] = Digest::SHA256.hexdigest(JSON.generate(context)).first(16)
      context
    end

    def render_requested(evidence)
      context = evidence.filter_map { |item| item['refunded_orders'] }.find do |item|
        item['source'].blank? && item.dig('period', 'from') == (Date.current - 29).iso8601 && item.dig('period', 'to') == Date.current.iso8601
      end
      return unless context

      lines = ["Recorded orders currently marked refunded, by order date (#{context.dig('period', 'from')} to #{context.dig('period', 'to')}):"]
      if context['counts'].empty?
        lines << 'No refunded orders were returned for the included sources.'
      else
        context['counts'].each { |source, count| lines << "- #{source}: #{count} #{count == 1 ? 'order' : 'orders'}." }
      end
      lines << 'This uses order date and current order status, not refund date or refund transactions. Missing source data does not prove no refunds; C-Trax and SwipeSimple are excluded.'
      lines.join("\n")
    end
  end
end
