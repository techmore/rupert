# frozen_string_literal: true
module Money
  # Convert a money amount to integer cents.
  #
  # Accepts either a Shopify JSON hash key (e.g. hash["amount"] => "63.60")
  # or a raw string that may contain dollar signs, commas, or whitespace
  # (as imported from Square CSV).
  #
  # Returns +nil+ if the amount is blank; otherwise an integer number of cents.
  def self.cents_from_amount(amount)
    return if amount.blank?

    cleaned = amount.to_s.gsub(/[$,\s]/, "")
    (cleaned.to_f * 100).round
  end
end