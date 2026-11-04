# frozen_string_literal: true

require 'json'

# Scores one Ask Rupert eval turn. Plain Ruby (no Rails), so the eval can run
# against a model server from any machine with Ruby.
module AskRupertEval
  module Scoring
    module_function

    # A string expectation: "/.../i" is a regular expression, anything else is exact.
    def value_matches?(expected, actual)
      return expected.any? { |option| value_matches?(option, actual) } if expected.is_a?(Array)
      return actual.nil? if expected.nil?
      return false if actual.nil?

      if expected.is_a?(String) && (match = expected.match(%r{\A/(.*)/([imx]*)\z}m))
        options = (match[2].include?('i') ? Regexp::IGNORECASE : 0) | (match[2].include?('m') ? Regexp::MULTILINE : 0)
        return Regexp.new(match[1], options).match?(actual.to_s)
      end
      expected.to_s == actual.to_s
    end

    def dig(hash, path)
      path.to_s.split('.').reduce(hash) { |node, key| node.is_a?(Hash) ? node[key] : nil }
    end

    # Was the first move right? Returns [ok, reason].
    def first_call_ok(expect, call)
      wanted = expect['tool'].to_s
      also = Array(expect['also']).map(&:to_s)
      return [true, nil] if call.nil? && wanted == 'none'
      return [false, "no tool call, expected #{wanted}"] if call.nil?
      return [true, nil] if also.include?(call['name'])
      return [false, "called #{call['name']}, expected #{wanted}"] unless call['name'] == wanted

      (expect['args'] || {}).each do |path, expected|
        actual = dig(call['arguments'], path)
        return [false, "#{path}=#{actual.inspect}, expected #{expected.inspect}"] unless value_matches?(expected, actual)
      end
      [true, nil]
    end

    # Does the final answer say what it must, avoid what it must not, and link only real paths?
    def answer_ok(expect, answer, known_paths)
      text = answer.to_s
      return [false, 'no answer'] if text.strip.empty?

      Array(expect['answer']).each do |pattern|
        return [false, "missing #{pattern}"] unless Regexp.new(pattern).match?(text)
      end
      Array(expect['forbid']).each do |pattern|
        return [false, "says #{pattern}"] if Regexp.new(pattern).match?(text)
      end
      invented = invented_paths(text, known_paths)
      return [false, "invented path #{invented.first}"] if invented.any?

      [true, nil]
    end

    # Markdown link targets that the model was never given.
    def invented_paths(text, known_paths)
      text.scan(%r{\]\((/[^)\s]*)\)}).flatten.map { |path| path.split(/[?#]/).first }.uniq.reject do |path|
        known_paths.any? { |known| known.split(/[?#]/).first == path }
      end
    end

    # Every site path that appears in text the model was shown.
    def paths_in(text)
      text.to_s.scan(%r{(?<![\w.])(/[a-z][a-z0-9_/-]*)}).flatten.uniq
    end

    # The same checks LocalGateway applies before Rupert runs a call. Returns nil or a problem.
    def schema_problem(schema, value)
      return 'arguments are not an object' unless value.is_a?(Hash)

      properties = schema['properties'] || {}
      missing = Array(schema['required']) - value.keys
      return "missing #{missing.join(', ')}" if missing.any?

      extra = value.keys - properties.keys
      return "unknown argument #{extra.first}" if extra.any? && schema['additionalProperties'] == false

      value.each do |key, item|
        spec = properties[key] || {}
        problem = type_problem(spec, item)
        return "#{key} #{problem}" if problem
      end
      nil
    end

    def type_problem(spec, item)
      case spec['type']
      when 'string'
        return 'is not a string' unless item.is_a?(String)
        return 'is too short' if spec['minLength'] && item.length < spec['minLength']
        return 'is too long' if spec['maxLength'] && item.length > spec['maxLength']
        return 'is not an allowed value' if spec['enum'] && !spec['enum'].include?(item)
      when 'object' then return 'is not an object' unless item.is_a?(Hash)
      when 'integer' then return 'is not an integer' unless item.is_a?(Integer)
      when 'boolean' then return 'is not true/false' unless [true, false].include?(item)
      end
      nil
    end

    def percentile(values, fraction)
      sorted = values.compact.sort
      return nil if sorted.empty?

      sorted[[(sorted.length * fraction).ceil - 1, 0].max] # nearest rank
    end

    # One line per run for the docs table.
    def summary(results)
      cases = results.length
      tool_ok = results.count { |row| row['tool_ok'] }
      answer_ok = results.count { |row| row['answer_ok'] }
      both = results.count { |row| row['tool_ok'] && row['answer_ok'] }
      ttft = results.map { |row| row['ttft_ms'] }
      total = results.map { |row| row['total_ms'] }
      {
        'cases' => cases, 'tool_ok' => tool_ok, 'answer_ok' => answer_ok, 'both_ok' => both,
        'protocol_errors' => results.count { |row| row['error'] },
        'ttft_ms_p50' => percentile(ttft, 0.5), 'ttft_ms_p90' => percentile(ttft, 0.9),
        'total_ms_p50' => percentile(total, 0.5), 'total_ms_p90' => percentile(total, 0.9),
        'tokens_out' => results.sum { |row| row['tokens_out'].to_i }
      }
    end
  end
end
