# frozen_string_literal: true

module TeamChat
  # A spoken question is posted straight away, so a misheard date would run a lookup for the wrong period without anyone seeing it
  # first. The 2026-10-28 speech measurements showed the year is the weak spot ("2026" came back as "226", "2006" or "2016" while the
  # month and day were right). This flags a transcript whose date looks wrong, so the client can hold it in the message box to check.
  module VoiceCheck
    MONTHS = %w[january february march april may june july august september october november december].freeze
    MONTH = MONTHS.join('|')
    # Years more than this many away from today are treated as misheard (nobody asks about 2006 in a business assistant).
    YEAR_SPAN = 1
    FULL_YEAR = /\b((?:19|20)\d{2})\b/
    # "September 1st, 226": a month and day followed by a number that is too short to be a year, at the end of the phrase or before a range word
    # (so "September 3rd, 12 orders" is left alone).
    SHORT_YEAR = /\b(?:#{MONTH})\s+(?:the\s+)?\d{1,2}(?:st|nd|rd|th)?\s*,?\s+(\d{1,3})(?=\s*(?:[,.?!]|\z|\s(?:to|and|through|until|with|vs|versus|from|compared)\b))/i

    module_function

    # nil when the transcript is fine, else a short sentence for the person.
    def review_reason(text, today: Date.current)
      text = text.to_s
      years = text.scan(FULL_YEAR).flatten.map(&:to_i)
      far = years.find { |year| (year - today.year).abs > YEAR_SPAN }
      return "I heard the year #{far}. Check the date, then send." if far

      short = text[SHORT_YEAR, 1]
      return "I heard “#{short}” where a year should be. Check the date, then send." if short

      nil
    end
  end
end
