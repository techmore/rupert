# frozen_string_literal: true

module Core
  # Payment tender applied to an order (card, cash, gift card, etc.).
  class Payment < ApplicationRecord
    include TenantScoped
    include UuidId

    self.table_name = "payments"

    METHODS = ["card", "cash", "gift_card", "check", "other"].freeze

    belongs_to :order, class_name: "Core::Order", foreign_key: :order_id

    validates :method, presence: true
    validates :amount_cents, numericality: { greater_than: 0 }
    validates :paid_at, presence: true

    scope :completed, -> { where(status: "completed") }
  end
end
