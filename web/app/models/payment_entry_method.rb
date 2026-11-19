# frozen_string_literal: true

# How a card was presented for a payment: one short word from a fixed list, kept for
# receipts and reconciliation. NULL means it was never recorded (older payments, cash,
# and gateways that do not report it). "unknown" means a terminal took the card but
# reported no entry type Rupert recognises. Nothing else about the card read is kept.
module PaymentEntryMethod
  VALUES = %w[tap chip swipe keyed unknown].freeze
  # Receipt wording. "unknown" has none: a receipt says nothing rather than "Unknown".
  LABELS = { 'tap' => 'Contactless', 'chip' => 'Chip', 'swipe' => 'Swipe', 'keyed' => 'Keyed' }.freeze

  def self.label(value) = LABELS[value.to_s]
end
