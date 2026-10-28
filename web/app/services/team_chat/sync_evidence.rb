# frozen_string_literal: true

module TeamChat
  # A bounded rendering of the authorized sync-health result. An acquisition
  # timestamp alone cannot establish complete sales coverage.
  module SyncEvidence
    module_function

    def render(entries)
      entries.filter_map { |entry| section(entry) }.uniq.first(2).join("\n\n").presence
    end

    def section(entry)
      return unless entry['name'] == 'sync_health'

      data = JSON.parse(entry['result'].to_s.partition("\n").last)
      channels = data.fetch('channels')
      return unless channels.is_a?(Array)

      lines = ['Source sync health:']
      lines << 'No source operations were reported.' if channels.empty?
      channels.first(12).each do |row|
        next unless row.is_a?(Hash)

        source = label(row['source'].presence || 'unknown source')
        operation = label(row['operation'].presence || 'unknown operation')
        status = %w[succeeded failed running queued skipped].include?(row['latest_status']) ? row['latest_status'] : 'unknown'
        last = row['last_success_at'].to_s
        last = nil unless last.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/)
        lines << "- #{source} / #{operation}: #{status}#{last ? "; last successful acquisition #{last}" : '; no known successful acquisition'}."
      end
      lines << 'Additional source operations were omitted.' if channels.size > 12
      lines << 'Acquisition time alone does not establish complete sales coverage.'
      lines.join("\n")
    rescue JSON::ParserError, KeyError, TypeError
      nil
    end

    def label(value)
      AskRupert::Redactor.personal(value.to_s).gsub(/[\r\n\[\]<>`]/, ' ').squish.first(100)
    end
  end
end
