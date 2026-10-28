# frozen_string_literal: true

module TeamChat
  # Preserve the authorized compliance lookup when a financial answer needs
  # deterministic rendering. Missing or truncated results are not an all-clear.
  module ComplianceEvidence
    module_function

    RETENTION_TITLE = 'Google Drive document retention'
    TIMESHEETS_TITLE = 'Timesheets awaiting approval'
    BANK_LINES_TITLE = 'Uploaded bank lines have a decision'

    def close_scope(question)
      text = question.to_s.sub(/\A\s*(?:@[\w.-]+\s+)+/, '').strip.downcase
      return unless text.match?(/\A(?:is last month closed in the books|are last month's books closed)[?.!]*(?:\s+what (?:is|is still|is left|remains) (?:open|to do)[?.!]*)?\z/)

      'Month close'
    end

    # Only a complete, single-subject status question uses the focused path.
    def retention_question?(question)
      text = question.to_s.sub(/\A\s*(?:@[\w.-]+\s+)+/, '').strip.sub(/[?.!]+\z/, '').strip
      return false if text.match?(/\b(?:and|or|but|also)\b|[;!?]/i)

      text.match?(/\A(?:is|are|does|can|what|how)\b.{0,100}\bdocument(?:s)?\s+retention\b.{0,80}\bgoogle\s+drive(?:\s+(?:working|connected|enabled|current|operational|healthy|ok))?\z/i)
    end

    def focused_title(question)
      return RETENTION_TITLE if retention_question?(question)
      return RETENTION_TITLE if retention_and_backup_question?(question)
      return TIMESHEETS_TITLE if timesheets_and_backup_question?(question)

      text = question.to_s.sub(/\A\s*(?:@[\w.-]+\s+)+/, '').strip.sub(/[?.!]+\z/, '').strip
      return TIMESHEETS_TITLE if text.match?(/\A(?:are there|are|any|how many) (?:any )?timesheets (?:are )?(?:waiting for|awaiting|pending) approval\z/i)
      return BANK_LINES_TITLE if text.match?(/\A(?:are there|are|any|how many) (?:any )?bank statement lines (?:are )?(?:waiting to be matched|awaiting (?:a )?decision|pending (?:a )?decision)\z/i)

      nil
    end

    def retention_and_backup_question?(question)
      text = question.to_s.sub(/\A\s*(?:@[\w.-]+\s+)+/, '').strip.sub(/[?.!]+\z/, '').strip
      parts = text.split(/\s+and\s+/i)
      parts.size == 2 && retention_question?(parts.first) && parts.last.match?(/\A(?:are )?backups (?:current|fresh)\z/i)
    end

    def timesheets_and_backup_question?(question)
      text = question.to_s.sub(/\A\s*(?:@[\w.-]+\s+)+/, '').strip.sub(/[?.!]+\z/, '').strip
      text.match?(/\A(?:are there|are|any|how many) (?:any )?timesheets (?:are )?(?:waiting for|awaiting|pending) approval and (?:are )?backups (?:current|fresh)\z/i)
    end

    def narrow_title(question)
      focused_title(question) unless timesheets_and_backup_question?(question) || retention_and_backup_question?(question)
    end

    # Keep structured evidence parseable within the toolbox's result limit.
    # Do not include unrelated fields or personal contact details.
    def pack(data = nil, requested_title: nil, requested_area: nil, **data_keywords)
      data = (data || data_keywords).deep_stringify_keys
      items = data.fetch('items')
      raise ArgumentError unless items.is_a?(Array)

      rows = items.filter_map do |item|
        next unless item.is_a?(Hash) && %w[fix watch unknown ok].include?(item['status'])

        row = { 'title' => label(item['title']), 'area' => label(item['area']), 'status' => item['status'],
                'detail' => label(item['detail']) }
        row['count'] = item['count'] if item['count'].is_a?(Integer) && item['count'] >= 0
        if item['topics'].is_a?(Array)
          row['topics'] = item['topics'].first(8).filter_map { |topic| label(topic).presence }
        end
        row
      end
      # Keep actionable and uncertain items ahead of completed checks when the
      # result must be shortened, while preserving their original relative order.
      rows = rows.partition { |row| row['status'] != 'ok' }.flatten(1)
      if requested_title && (requested = rows.find { |row| row['title'] == requested_title })
        rows = [requested] + rows.reject { |row| row.equal?(requested) }
      end
      rows = rows.partition { |row| row['area'] == requested_area }.flatten(1) if requested_area
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

    def render_close(entries, area)
      entries.each do |entry|
        next unless entry['name'] == 'compliance_check'

        data = JSON.parse(entry['result'].to_s.partition("\n").last)
        rows = Array(data['items']).select { |item| item.is_a?(Hash) && item['area'] == area }
        locks = rows.select { |row| row['title'].to_s.end_with?(': Lock the month') }
        next unless locks.one?

        lock = locks.first
        detail = label(lock['detail'])
        state = if lock['status'] == 'ok' && detail.start_with?('Locked by ')
          'Locked.'
        elsif detail.start_with?('Locked, but records changed afterwards:')
          'Locked, but records changed after the lock.'
        elsif %w[watch fix].include?(lock['status']) && (detail.start_with?('You can lock now') || detail.start_with?('Everything above is done. Lock it'))
          'Not locked.'
        else
          'Lock state could not be determined from the checklist.'
        end
        lines = ["#{label(lock['title'].split(':', 2).first)}: #{state}", "Lock check: #{detail.presence || 'No detail returned.'}"]
        open = rows.select { |row| %w[fix watch unknown].include?(row['status']) && row != lock }
        lines << 'Open or uncertain checklist items:' if open.any?
        open.each { |row| lines << "- #{label(row['title'])} (#{row['status']}): #{label(row['detail'])}." }
        lines << 'Additional checklist items may have been omitted.' if data['omitted'] == true
        return lines.join("\n")
      rescue JSON::ParserError, TypeError
        next
      end
      nil
    end

    def render_retention(entries)
      entries.each do |entry|
        next unless entry['name'] == 'compliance_check'

        data = JSON.parse(entry['result'].to_s.partition("\n").last)
        row = Array(data['items']).find { |item| item.is_a?(Hash) && item['title'] == RETENTION_TITLE && %w[fix watch unknown ok].include?(item['status']) }
        next unless row

        detail = label(row['detail'])
        return "Recorded document-retention status (#{row['status']}): #{detail.presence || 'No detail was returned.'}"
      rescue JSON::ParserError, TypeError
        next
      end
      nil
    end

    def render_focused_count(entries, title)
      entries.each do |entry|
        next unless entry['name'] == 'compliance_check'

        data = JSON.parse(entry['result'].to_s.partition("\n").last)
        row = Array(data['items']).find { |item| item.is_a?(Hash) && item['title'] == title }
        next unless row && %w[fix watch ok].include?(row['status']) && row['count'].is_a?(Integer) && row['count'] >= 0

        if title == TIMESHEETS_TITLE
          return "Recorded non-demo submitted timesheets awaiting approval: #{row['count']}."
        elsif title == BANK_LINES_TITLE
          return "Uploaded bank statement lines awaiting a decision: #{row['count']}. Decided lines may have been ignored; this does not establish that every line was matched."
        end
      rescue JSON::ParserError, TypeError
        next
      end
      nil
    end

    def render_backup_freshness(entries)
      entries.each do |entry|
        next unless entry['name'] == 'backup_freshness'

        data = JSON.parse(entry['result'].to_s.partition("\n").last)
        drive = data['drive']
        next unless drive.is_a?(Hash) && drive['fresh_within_hours'] == 8 && [true, false].include?(drive['fresh']) && drive['last_success_age_hours'].is_a?(Numeric) && drive['last_success_age_hours'] >= 0
        next unless drive['last_success_age_hours'].finite? && drive['fresh'] == (drive['last_success_age_hours'] <= 8)

        state = drive['fresh'] ? 'within the last 8 hours' : 'more than 8 hours ago'
        return "The last verified Google Drive backup was #{state}. Other backup layers were not assessed in this summary."
      rescue JSON::ParserError, TypeError
        next
      end
      nil
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
