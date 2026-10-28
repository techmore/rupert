# frozen_string_literal: true

module TeamChat
  # Refunded orders are counted by their order date and current status, not by
  # refund transaction date or amount. Keep that distinction visible.
  module RefundEvidence
    module_function

    def count_question?(question)
      text = question.to_s.sub(/\A\s*(?:@[\w.-]+\s+)+/, '').strip.sub(/[?.!]+\z/, '').strip
      text.match?(/\Ahow many orders (?:were|have been) refunded (?:in|over) the last 30 days(?:,? and (?:from )?which sources)?\z/i) || explicit_period_for(text).present?
    end

    # Explicit order-date ranges are distinct from refund transaction dates.
    # With no stated year, only dates already reached in this calendar year are
    # accepted; the rendered answer shows the resolved dates.
    def explicit_period_for(question)
      text = question.to_s.downcase
      return unless text.match?(/\borders?\b/) && text.match?(/\brefund(?:ed)?\b/) && text.match?(/\b(?:how many|count)\b/)
      return if text.match?(/\b(?:transactions?|amount|rate|compare|versus|also|plus|only|shopify|square|manual|ctrax|swipesimple|product|sku|item|customer|location|store|brand|category)\b/)
      return if text.match?(/\b(?:rupert[ _-]+pos|in person)\b/)
      return if text.match?(/\band\b/) && !text.match?(/\band (?:from )?which sources\b/)
      dates = text.scan(/\b\d{4}-\d{2}-\d{2}\b/)
      if dates.size == 2 && text.match?(/\b#{Regexp.escape(dates[0])}\s+(?:through|to)\s+#{Regexp.escape(dates[1])}\b/)
        from, to = dates.map { |date| Date.iso8601(date) }
      elsif dates.empty?
        match = text.match(/\b(january|february|march|april|may|june|july|august|september|october|november|december)\s+(\d{1,2})\s+(?:through|to)\s+(january|february|march|april|may|june|july|august|september|october|november|december)\s+(\d{1,2})(?:,?\s+(\d{4}))?\b/)
        return unless match

        year = match[5]&.to_i || Date.current.year
        from = Date.strptime("#{match[1]} #{match[2]} #{year}", '%B %d %Y')
        to = Date.strptime("#{match[3]} #{match[4]} #{year}", '%B %d %Y')
        return if match[5].nil? && to > Date.current
      else
        return
      end
      return unless from <= to && (to - from).to_i <= 366

      { 'from' => from.iso8601, 'to' => to.iso8601 }
    rescue Date::Error, ArgumentError
      nil
    end

    def build(data, period, source)
      counts = data['refunded_orders_by_source']
      return unless counts.is_a?(Hash)
      return unless counts.all? { |key, value| Mcp::Tools::SalesSummary::SOURCES.include?(key) && value.is_a?(Integer) && value.positive? && (source.blank? || key == source) }

      context = { 'period' => period, 'source' => source, 'counts' => counts.sort.to_h }
      context['id'] = Digest::SHA256.hexdigest(JSON.generate(context)).first(16)
      context
    end

    def render_requested(evidence, question: nil)
      period = explicit_period_for(question) || { 'from' => (Date.current - 29).iso8601, 'to' => Date.current.iso8601 }
      context = evidence.filter_map { |item| item['refunded_orders'] }.find do |item|
        item['source'].blank? && item['period'] == period
      end
      return unless context

      lines = ["Recorded orders currently marked refunded, by order date (#{context.dig('period', 'from')} to #{context.dig('period', 'to')}):"]
      if context['counts'].empty?
        lines << 'No refunded orders were returned for the included sources.'
      else
        context['counts'].each { |source, count| lines << "- #{source}: #{count} #{count == 1 ? 'order' : 'orders'}." }
      end
      lines << 'This uses order date and current order status, not refund date or refund transactions. A partial refund does not necessarily put an order in refunded status. Missing source data does not prove no refunds; C-Trax and SwipeSimple are excluded.'
      lines.join("\n")
    end
  end
end
