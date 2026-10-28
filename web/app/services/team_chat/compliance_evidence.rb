# frozen_string_literal: true

module TeamChat
  # Preserve the authorized compliance lookup when a financial answer needs
  # deterministic rendering. Missing or truncated results are not an all-clear.
  module ComplianceEvidence
    module_function

    # Keep structured evidence parseable within the toolbox's result limit.
    # Do not include unrelated fields or personal contact details.
    def pack(data)
      data = data.deep_stringify_keys
      items = data.fetch('items')
      raise ArgumentError unless items.is_a?(Array)

      rows = items.filter_map do |item|
        next unless item.is_a?(Hash) && %w[fix watch unknown ok].include?(item['status'])

        { 'title' => label(item['title']), 'area' => label(item['area']), 'status' => item['status'],
          'detail' => label(item['detail']) }
      end
      packed = { 'items' => rows.first(20), 'omitted' => rows.size > 20 }
      if data['counts'].is_a?(Hash)
        packed['counts'] = data['counts'].select { |key, value| %w[fix watch unknown ok].include?(key) && value.is_a?(Integer) && value >= 0 }
      end
      while JSON.generate(packed).length > 5_000 && packed['items'].any?
        packed['items'].pop
        packed['omitted'] = true
      end
      packed
    end

    def render(entries)
      sections = entries.filter_map { |entry| section(entry) }.uniq
      sections.first(2).join("\n\n").presence
    end

    def section(entry)
      return unless entry['name'] == 'compliance_check'

      data = JSON.parse(entry['result'].to_s.partition("\n").last)
      items = data.fetch('items')
      return unless items.is_a?(Array)

      relevant = items.select { |item| item.is_a?(Hash) && %w[fix watch unknown].include?(item['status']) }
      lines = ['Compliance check:']
      lines << 'No fix, watch, or unknown items were returned.' if relevant.empty?
      relevant.first(12).each do |item|
        title = label(item['title'].presence || 'Unnamed item')
        area = label(item['area'].presence || 'Unspecified area')
        detail = label(item['detail'])
        lines << "- #{title} (#{area}; #{item['status']})#{detail.present? ? ": #{detail}" : '.'}"
      end
      lines << 'Additional compliance items were omitted.' if relevant.size > 12 || data['omitted'] == true
      lines.join("\n")
    rescue JSON::ParserError, KeyError, TypeError
      nil
    end

    def label(value)
      AskRupert::Redactor.personal(value.to_s).gsub(/[\r\n\[\]<>`]/, ' ').squish.first(200)
    end
  end
end
