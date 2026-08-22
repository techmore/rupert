# frozen_string_literal: true

module Core
  # Line item on a canonical order.
  class OrderLine < ApplicationRecord
    include TenantScoped

    self.table_name = 'order_lines'

    belongs_to :order, class_name: 'Core::Order', foreign_key: :order_id

    validates :name, presence: true
    validates :quantity, numericality: { greater_than_or_equal_to: 0 }

    def line_cents_from_unit
      unit_cents * quantity
    end
  end
end
