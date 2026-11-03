# frozen_string_literal: true

# Finds and removes payment card data from free text: full card numbers (PAN),
# magnetic-stripe track data and labelled security codes.
#
# Rupert never receives card data by design. Card entry happens in the
# processor's hosted fields or on a standalone terminal, and Rupert only sees
# tokens, transaction ids and amounts. This module is the backstop for text a
# person or a library writes anyway: logs, error reports, bug reports, team chat
# and prompts sent to an AI provider.
#
# A card number is 13-19 digits, optionally grouped by single spaces or dashes,
# that starts with 2-6 (the major card brands) and passes the Luhn check.
# Letters may touch it ("pan4111..."), other digits may not.
module CardData
  REPLACEMENT = '[card removed]'
  CODE_REPLACEMENT = '[code removed]'

  # Track 1: %B<PAN>^<NAME>^<YYMM><service code><discretionary>?
  TRACK1 = /%?[Bb]\d{12,19}\^[^\^\n]{0,26}\^\d{4}[^\s?]*\??/
  # Track 2 (and EMV tag 57, which uses D as the separator): ;<PAN>=<YYMM>...?
  TRACK2 = /;?(?<!\d)\d{12,19}[=Dd]\d{4}\d*\??/
  # A run of digits with optional single space/dash separators, at least 13 digits.
  RUN = /(?<!\d)\d(?:[ -]?\d){12,}(?!\d)/
  # "cvv 123", "CVC: 123", "security code 1234". Key=value pairs are also hidden by the
  # request-log parameter filter; this catches the label in ordinary sentences.
  SECURITY_CODE = /\b(cvv2?|cvc2?|cid|csc|card[ _-]?code|security[ _-]?code)(\s*[=:#-]?\s*)\d{3,4}\b/i
  MIN_DIGITS = 12

  module_function

  # The text with card numbers, track data and labelled security codes replaced.
  def redact(text)
    return text unless text.is_a?(String)

    out = text
    out = out.gsub(SECURITY_CODE) { "#{Regexp.last_match(1)}#{Regexp.last_match(2)}#{CODE_REPLACEMENT}" } if out.match?(/c[vs]c|cvv|cid|code/i)
    return out if out.count('0-9') < MIN_DIGITS

    out.gsub(TRACK1, REPLACEMENT).gsub(TRACK2, REPLACEMENT).gsub(RUN) { |run| pan_in_run?(run) ? REPLACEMENT : run }
  end

  # True when the text holds anything redact would remove.
  def contains?(text)
    text.is_a?(String) && redact(text) != text
  end

  # A run counts when a card number starts at the beginning of the run or of one of
  # its groups, and ends at the end of a group (or anywhere, for an ungrouped run,
  # so a card number glued to its expiry date is still found). Requiring group
  # boundaries keeps long grouped numbers such as parcel tracking ids intact.
  def pan_in_run?(run)
    groups = run.split(/[ -]/)
    digits = groups.join
    return (13..[19, digits.length].min).any? { |length| pan?(digits[0, length]) } if groups.one?

    edges = groups.each_with_object([0]) { |group, acc| acc << (acc.last + group.length) }
    edges[0...-1].any? do |start|
      edges.any? { |finish| (13..19).cover?(finish - start) && pan?(digits[start...finish]) }
    end
  end

  def pan?(digits)
    digits.length.between?(13, 19) && digits[0].between?('2', '6') && luhn?(digits)
  end

  def luhn?(digits)
    sum = 0
    digits.reverse.each_char.with_index do |char, index|
      value = char.ord - 48
      if index.odd?
        value *= 2
        value -= 9 if value > 9
      end
      sum += value
    end
    (sum % 10).zero?
  end
end
