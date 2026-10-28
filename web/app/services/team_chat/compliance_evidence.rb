# frozen_string_literal: true

module TeamChat
  # Preserve the authorized compliance lookup when a financial answer needs
  # deterministic rendering. Missing or truncated results are not an all-clear.
  module ComplianceEvidence
    module_function

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
      lines << 'Additional compliance items were omitted.' if relevant.size > 12
      lines.join("\n")
    rescue JSON::ParserError, KeyError, TypeError
      nil
    end

    def label(value)
      AskRupert::Redactor.personal(value.to_s).gsub(/[\r\n\[\]<>`]/, ' ').squish.first(200)
    end
  end
end
