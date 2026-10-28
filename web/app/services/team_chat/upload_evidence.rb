# frozen_string_literal: true

module TeamChat
  # The newest unfiltered inbox lookup can answer a question about the last
  # upload. A filtered or later page cannot establish which upload was latest.
  module UploadEvidence
    module_function

    def last_upload_question?(text)
      question = text.to_s.sub(/\A\s*(?:@[\w.-]+\s+)+/, '').strip
      question.match?(/\Awhat happened to (?:my|the) (?:last|latest|most recent) (?:file|upload|import)(?: i tried to import)?[?.!]*\z/i)
    end

    def render_last(entries)
      entries.reverse_each do |entry|
        next unless entry['name'] == 'list_uploads'

        args = entry['arguments'].is_a?(Hash) ? entry['arguments'] : {}
        next if %w[id query sha256 status].any? { |key| args[key].present? }
        next if args['page'].present? && args['page'].to_i != 1

        data = JSON.parse(entry['result'].to_s.partition("\n").last)
        rows = data.fetch('rows')
        return unless rows.is_a?(Array)
        return 'No uploads were returned in the current Uploads inbox. I cannot determine what happened to the last attempted import from that alone.' if rows.empty?

        row = rows.first
        return unless row.is_a?(Hash) && Upload::STATUSES.include?(row['status'])

        filename = AskRupert::Redactor.personal(row['filename'].to_s).gsub(/[\r\n\[\]<>`]/, ' ').squish.first(100)
        return if filename.blank?

        return "Most recent file in the current Uploads inbox: #{filename} (#{row['status'].tr('_', ' ')}). I cannot confirm whether this is the last file you tried to import."
      end
      nil
    rescue JSON::ParserError, KeyError, TypeError
      nil
    end
  end
end
