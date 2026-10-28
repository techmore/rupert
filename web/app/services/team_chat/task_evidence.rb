# frozen_string_literal: true

module TeamChat
  # A bounded fallback for an authorized list_tasks result, preserving the
  # filters so that an empty result is not mistaken for an empty task board.
  module TaskEvidence
    FILTERS = %w[query status priority topic overdue assigned_to_me page per_page].freeze

    module_function

    def render(entries)
      sections = entries.filter_map { |entry| section(entry) }.uniq
      return nil if sections.empty?

      sections.first(4).join("\n\n") + (sections.size > 4 ? "\nAdditional task lookups were omitted." : '')
    end

    def section(entry)
      return unless entry['name'] == 'list_tasks'

      data = JSON.parse(entry['result'].to_s.partition("\n").last)
      rows = data.fetch('rows')
      meta = data.fetch('meta')
      return unless rows.is_a?(Array) && meta.is_a?(Hash)

      args = entry['arguments'].is_a?(Hash) ? entry['arguments'] : {}
      filters = FILTERS.filter_map do |key|
        value = args[key]
        next if value.nil? || value == '' || value == false

        "#{key.tr('_', ' ')}: #{label(value)}"
      end
      scope = filters.any? ? filters.join(', ') : 'default: tasks except done'
      lines = ["Task lookup (#{scope}):"]
      lines << 'No tasks were returned on this page.' if rows.empty?
      rows.first(10).each do |row|
        next unless row.is_a?(Hash)

        title = label(row['title'].presence || 'Untitled task')
        status = label(row['status'].presence || 'unknown status')
        due = row['due_on'].to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? "; due #{row['due_on']}" : ''
        lines << "- #{title} (#{status}#{due})."
      end
      lines << 'More tasks are available; this lookup is paginated.' if meta['has_more'] == true || rows.size > 10
      lines.join("\n")
    rescue JSON::ParserError, KeyError, TypeError
      nil
    end

    def label(value)
      AskRupert::Redactor.personal(value.to_s).gsub(/[\r\n\[\]<>`]/, ' ').squish.first(100)
    end
  end
end
