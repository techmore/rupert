# frozen_string_literal: true

module Core
  # Canonical sales order. Fed by the sync engine (Shopify + Square), with
  # POS sessions and manual sales writing here too. `source + source_order_id`
  # is the idempotency key.
  class Order < ApplicationRecord
    include TenantScoped
    include AASM

    self.table_name = "orders"

    CHANNELS = ["online", "pos", "manual"].freeze

    belongs_to :customer, class_name: "Core::Customer", optional: true
    belongs_to :location, class_name: "Location", foreign_key: :location_id, optional: true
    has_many :order_lines, class_name: "Core::OrderLine", foreign_key: :order_id, dependent: :destroy
    has_many :payments, class_name: "Core::Payment", foreign_key: :order_id, dependent: :destroy

    validates :source, presence: true
    validates :source_order_id, presence: true
    validates :occurred_at, presence: true
    validates :status, presence: true

    scope :recent, ->(limit = 200) { order(occurred_at: :desc).limit(limit) }
    scope :since, ->(date) { where("occurred_at >= ?", date) }
    scope :on_day, ->(date) { where(occurred_at: date.beginning_of_day...date.end_of_day) }
    scope :by_source, ->(source) { source.present? && source != "all" ? where(source: source) : all }

    aasm column: "status", no_direct_assignment: true do
      state :placed, initial: true
      state :paid
      state :fulfilled
      state :refunded
      state :cancelled

      event :mark_paid do
        transitions from: :placed, to: :paid
      end
      event :fulfill do
        transitions from: :paid, to: :fulfilled
      end
      event :refund do
        transitions from: [:paid, :fulfilled], to: :refunded
      end
      event :cancel do
        transitions from: :placed, to: :cancelled
      end
    end

    def total_paid_cents
      payments.completed.sum(:amount_cents)
    end

    def balance_due_cents
      gross_cents - total_paid_cents
    end
  end
end
