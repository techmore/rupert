# frozen_string_literal: true

module AskRupert
  # Keeps secrets and other people's contact details out of model prompts.
  # Text from people, pages and records is untrusted; this removes the parts
  # that must never leave Rupert, whichever model is answering.
  module Redactor
    SECRET = /\b(?:rupert_[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,})\b|Bearer\s+[A-Za-z0-9._~+\/=-]{16,}/
    CARD = /\b(?:\d[ -]?){12,18}\d\b/
    EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/
    PHONE = /(?<![\w.])\+?\d[\d ().-]{7,}\d(?!\w|\.\d)/
    CONTROL = /[^\P{Cc}\n\t]/

    module_function

    # Typed text: control characters, keys, tokens and card-like numbers.
    def clean(text)
      text.to_s.scrub('').gsub(CONTROL, '').gsub(SECRET, '[secret removed]').gsub(CARD, '[number removed]').strip
    end

    # Tool results: the above plus emails and phone numbers of customers and staff.
    def personal(text)
      clean(text).gsub(EMAIL, '[email]').gsub(PHONE) do |match|
        # A period label may put two dates next to each other in parentheses.
        # Preserve only matches made entirely of valid dates and separators;
        # extra digits could be a phone number and must still be redacted.
        dates = match.scan(/\d{4}-\d{2}-\d{2}/)
        remainder = match.gsub(/\d{4}-\d{2}-\d{2}/, '').delete(' ()')
        if dates.any? && remainder.empty? && dates.all? { |date| Date.iso8601(date).iso8601 == date }
          match
        else
          '[phone]'
        end
      rescue Date::Error
        '[phone]'
      end
    end
  end
end
