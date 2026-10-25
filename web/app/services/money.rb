# frozen_string_literal: true

require 'bigdecimal'
require 'bigdecimal/util'

# Money is integer cents everywhere in Rupert. This module is the only place
# that converts between decimal amounts (platform JSON strings, form fields,
# CSV cells) and cents, and the only place that formats cents for people
# (docs/ui-standards.md §7: "$1,234.56", a real minus sign, "Unknown" for a
# missing amount). It never goes through a binary Float: "0.29" must be 29
# cents, not 28.999999999999996 rounded by luck.
#
# View helpers (finance_money, operations_money, ctrax_money, …) are thin
# names for Money.format with their page's options; the `.money` CSS class
# supplies tabular digits and the red negative colour.
module Money
  # U+2212, the real minus sign people read on screen.
  MINUS = "\u2212"
  # Dollars, commas, whitespace and an optional sign; at most two decimals.
  AMOUNT = /\A[+-]?\d{1,12}(?:\.\d{1,2})?\z/

  # Convert a money amount to integer cents. Accepts a Shopify-style decimal
  # string ("63.60"), a Square CSV cell ("$1,234.50"), a BigDecimal, an
  # Integer or a Float that came from a float column. Returns +nil+ when the
  # amount is blank or not a plain decimal number.
  def self.cents_from_amount(amount)
    decimal = to_decimal(amount)
    return if decimal.nil?

    (decimal * 100).round(0, BigDecimal::ROUND_HALF_UP).to_i
  end

  # Like cents_from_amount but raises ArgumentError for blank or malformed
  # input. Use this for anything a person typed (refund amounts, opening cash).
  def self.cents_from_amount!(amount, field: 'amount')
    cents = cents_from_amount(amount)
    raise ArgumentError, "#{field} must be a plain number with up to two decimals" if cents.nil?

    cents
  end

  # Integer cents -> BigDecimal amount (12.34). Never a Float.
  def self.amount_from_cents(cents)
    BigDecimal(cents.to_i) / 100
  end

  # Integer cents -> "12.34" string for display/CSV without Float formatting.
  def self.format_cents(cents)
    amount = amount_from_cents(cents)
    sign = amount.negative? ? '-' : ''
    whole, frac = amount.abs.to_s('F').split('.')
    "#{sign}#{whole}.#{(frac || '').ljust(2, '0')[0, 2]}"
  end

  # Integer cents -> display text.
  #
  #   Money.format(123_456)                  # => "$1,234.56"
  #   Money.format(-1)                       # => "−$0.01"
  #   Money.format(500, currency: 'CAD')     # => "CAD 5.00"
  #   Money.format(nil)                      # => "Unknown"
  #
  # currency:  USD shows "$"; any other code is written out (blank: "Unknown currency").
  # code:      :prefix ("CAD 5.00") or :suffix ("5.00 CAD") for non-USD codes.
  # unit:      false drops "$"/the code entirely ("1,234.56").
  # minus:     the sign for negatives; "-" only for plain-text channels that need ASCII.
  # missing:   what a nil amount reads as. Missing is never zero.
  # zero:      :dash shows "—" for an exact zero (debit/credit columns).
  # delimiter: the thousands separator ("" for none).
  # Fractional cents (a BigDecimal or Float from an average) round half up.
  def self.format(cents, currency: 'USD', code: :prefix, unit: true, minus: MINUS, missing: 'Unknown', zero: :show, delimiter: ',')
    return missing if cents.nil?

    value = whole_cents(cents)
    return '—' if value.zero? && zero == :dash

    whole, fraction = value.abs.divmod(100)
    digits = "#{ActiveSupport::NumberHelper.number_to_delimited(whole, delimiter: delimiter)}.#{Kernel.format('%02d', fraction)}"
    sign = value.negative? ? minus : ''
    return "#{sign}#{digits}" unless unit
    return "#{sign}$#{digits}" if currency.to_s.upcase == 'USD'

    label = currency.presence || 'Unknown currency'
    code == :suffix ? "#{sign}#{digits} #{label}" : "#{sign}#{label} #{digits}"
  end

  # Text a person typed -> integer cents, or nil when it is not a plain amount.
  # Accepts "6", "6.5", ".50", "$1,234.50" (dollar signs, commas and outer
  # spaces are ignored); at most two decimals. negative: false rejects a sign.
  # pattern: a stricter regexp the text must match exactly as typed (nothing
  # is stripped), for forms that refuse "$" and commas.
  def self.parse(text, negative: true, pattern: nil)
    cleaned = pattern ? text.to_s.strip : text.to_s.strip.delete('$,').strip
    return nil unless cleaned.match?(pattern || (negative ? PARSE_SIGNED : PARSE_UNSIGNED))

    (BigDecimal(cleaned) * 100).round(0, BigDecimal::ROUND_HALF_UP).to_i
  end

  PARSE_UNSIGNED = /\A(?:\d+(?:\.\d{1,2})?|\.\d{1,2})\z/
  PARSE_SIGNED = /\A[+-]?(?:\d+(?:\.\d{1,2})?|\.\d{1,2})\z/

  def self.whole_cents(cents)
    return cents if cents.is_a?(Integer)

    BigDecimal(cents.to_s).round(0, BigDecimal::ROUND_HALF_UP).to_i
  end
  private_class_method :whole_cents

  def self.to_decimal(amount)
    case amount
    when nil then nil
    when BigDecimal then amount
    when Integer then BigDecimal(amount)
    when Float then amount.finite? ? BigDecimal(amount.to_s) : nil
    else
      cleaned = amount.to_s.gsub(/[$,\s]/, '')
      return if cleaned.blank? || !cleaned.match?(AMOUNT)

      BigDecimal(cleaned)
    end
  end
  private_class_method :to_decimal
end
