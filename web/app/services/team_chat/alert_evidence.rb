# frozen_string_literal: true

module TeamChat
  # Alert quantities describe the alert record, not a fresh inventory check.
  module AlertEvidence
    module_function

    def pack(data, args: {})
      data = data.deep_stringify_keys
      rows = data.fetch('rows')
      meta = data.fetch('meta')
      raise ArgumentError unless rows.is_a?(Array) && meta.is_a?(Hash)

      packed = { 'rows' => rows.first(50).filter_map { |row| pack_row(row) },
                 'omitted' => rows.size > 50, 'has_more' => meta['has_more'],
                 'status' => label(args['status'].presence || 'open'), 'query' => label(args['query']) }
      packed['page'] = meta['page'] if meta['page'].is_a?(Integer) && meta['page'] > 0
      counts = data['counts']
      if counts.is_a?(Hash)
        packed['counts'] = counts.select { |key, value| %w[open resolved ignored].include?(key) && value.is_a?(Integer) && value >= 0 }
      end
      if JSON.generate(packed).length > 5_000 && packed['rows'].any? { |row| row.key?('note') }
        packed['rows'].each { |row| row.delete('note') }
        packed['notes_omitted'] = true
      end
      if JSON.generate(packed).length > 5_000 && packed['rows'].any? { |row| %w[id created_at resolved_at].any? { |key| row.key?(key) } }
        packed['rows'].each { |row| %w[id created_at resolved_at].each { |key| row.delete(key) } }
        packed['details_omitted'] = true
      end
      while JSON.generate(packed).length > 5_000 && packed['rows'].any?
        packed['rows'].pop
        packed['omitted'] = true
      end
      packed
    end

    def pack_row(row)
      return unless row.is_a?(Hash)

      result = %w[id sku product variant platform status note created_at resolved_at].filter_map do |key|
        value = label(row[key])
        [key, value] if value.present?
      end.to_h
      %w[quantity threshold].each { |key| result[key] = row[key] if row[key].is_a?(Integer) }
      result
    end

    def render(results)
      sections = results.filter_map { |result| section(result) }.uniq
      return nil if sections.empty?

      (sections.first(4) + (sections.size > 4 ? ['Additional alert lookups were omitted.'] : [])).join("\n\n")
    end

    def section(result)
      data = JSON.parse(result.to_s.partition("\n").last)
      rows = data.fetch('rows')
      return unless rows.is_a?(Array)

      lines = ['Low-stock alert records (not a current inventory check):']
      scope = "status: #{label(data['status'].presence || 'open')}"
      scope += "; query: #{label(data['query'])}" if data['query'].present?
      scope += "; page: #{data['page']}" if data['page'].is_a?(Integer) && data['page'] > 0
      lines << "Lookup filter (#{scope})."
      counts = data['counts']
      status_filter = data['status'].to_s
      if counts.is_a?(Hash) && %w[open resolved ignored].include?(status_filter) && counts[status_filter].is_a?(Integer) && counts[status_filter] >= 0
        lines << "All #{status_filter} alerts: #{counts[status_filter]}."
      end
      lines << 'No alert records were returned on this page.' if rows.empty?
      rows.each do |row|
        next unless row.is_a?(Hash)

        name = label(row['sku'].presence || row['product'].presence || 'Unnamed item')
        product = label(row['product'])
        variant = label(row['variant'])
        platform = label(row['platform'])
        status = label(row['status'].presence || 'unknown')
        quantity = row['quantity'].is_a?(Integer) ? row['quantity'] : 'unknown'
        threshold = row['threshold'].is_a?(Integer) ? row['threshold'] : 'unknown'
        details = [product.presence, variant.presence, platform.presence].compact.join('; ')
        details = " (#{details})" if details.present?
        created = row['created_at'].to_s[/\A\d{4}-\d{2}-\d{2}/]
        date = created ? "; alert created #{created}" : ''
        resolved = row['resolved_at'].to_s[/\A\d{4}-\d{2}-\d{2}/]
        date += "; resolved #{resolved}" if resolved
        id = row['id'].present? ? "; alert ID #{label(row['id'])}" : ''
        note = row['note'].present? ? "; note: #{label(row['note'])}" : ''
        lines << "- #{name}#{details}: alert quantity #{quantity}, threshold #{threshold}; status #{status}#{date}#{id}#{note}."
      end
      lines << 'More alert records are available or were omitted; narrow the lookup or check the next page.' if data['has_more'] == true || data['omitted'] == true
      lines << 'Alert notes were omitted; open the alert details for notes.' if data['notes_omitted'] == true
      lines << 'Alert IDs or dates were omitted; open the alert details for them.' if data['details_omitted'] == true
      lines << 'Pagination status is unknown; the lookup may be incomplete.' unless [true, false].include?(data['has_more'])
      lines << 'Alert quantities are recorded values and may be stale; check inventory for current availability.'
      lines.join("\n")
    rescue JSON::ParserError, KeyError, TypeError
      'The alert lookup could not be presented; try again or narrow the search.'
    end

    def label(value)
      AskRupert::Redactor.personal(value.to_s).gsub(/[\r\n\[\]<>`]/, ' ').squish.first(100)
    end
  end
end
