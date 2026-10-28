# frozen_string_literal: true

module TeamChat
  # Render only the fields returned by the authorized inventory lookup. Do not
  # infer that an inventory row matches a sales product or combine locations.
  module InventoryEvidence
    module_function

    def render(results)
      lines = results.flat_map { |result| rows_for(result) }.uniq
      return nil if lines.empty?

      (["Inventory observations (each source and location is separate; these are not automatically matched to sales products):"] + lines.first(10) +
        (lines.size > 10 ? ['Additional stock observations were omitted; narrow the search.'] : [])).join("\n")
    end

    def uncertain?(results)
      results.any? do |result|
        data = JSON.parse(result.to_s.partition("\n").last)
        rows = data.fetch('rows')
        meta = data.fetch('meta')
        !meta.is_a?(Hash) || meta['has_more'] != false || !rows.is_a?(Array) || rows.empty? || rows.any? do |row|
          !row.is_a?(Hash) || !row['available'].is_a?(Numeric) || ![true, false].include?(row['low'])
        end
      rescue JSON::ParserError, KeyError, TypeError
        true
      end
    end

    def rows_for(result)
      data = JSON.parse(result.to_s.partition("\n").last)
      rows = data.fetch('rows')
      meta = data.fetch('meta')
      return ['The stock lookup could not be presented; narrow the search.'] unless rows.is_a?(Array) && meta.is_a?(Hash)
      return ['No stock rows matched this lookup; availability is unknown.'] if rows.empty?

      lines = rows.filter_map do |row|
        next unless row.is_a?(Hash)

        name = label(row['name'].presence || row['sku'].presence || 'Unnamed item')
        location = label(row['location'].presence || row['location_id'].presence || 'unknown location')
        source = label(row['source'].presence || 'unknown source')
        available = row['available'].is_a?(Numeric) ? row['available'].to_s : 'unknown'
        low = row['low'] == true ? '; low stock' : (row['low'] == false ? '; not marked low stock' : '; low-stock status unknown')
        "- #{name} at #{location} (#{source}): #{available} available#{low}."
      end
      lines << 'More stock rows are available; this lookup is paginated.' if meta['has_more'] == true
      lines << 'Pagination status is unknown; this lookup may be incomplete.' unless [true, false].include?(meta['has_more'])
      lines
    rescue JSON::ParserError, KeyError, TypeError
      ['The stock lookup could not be presented; narrow the search.']
    end

    def label(value)
      AskRupert::Redactor.personal(value.to_s).gsub(/[\r\n\[\]<>`]/, ' ').squish.first(100)
    end
  end
end
