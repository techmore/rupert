# frozen_string_literal: true

module Purchasing
  # A supplier the shop buys from. Vendors can be attached to warehouse-sale
  # shares and own the purchase-order history.
  class Vendor < ApplicationRecord
    include TenantScoped

    self.table_name = 'vendors'

    PAYMENT_TERMS = %w[net7 net15 net30 net60 due_on_receipt prepaid].freeze

    has_many :purchase_orders,
             class_name: 'Purchasing::PurchaseOrder',
             foreign_key: :vendor_id,
             dependent: :restrict_with_exception

    validates :name, presence: true
    validates :payment_terms, inclusion: { in: PAYMENT_TERMS }, allow_nil: true

    scope :ordered, -> { order(:name) }
    scope :search, lambda { |q|
      return all if q.blank?

      where('name ILIKE ? OR email ILIKE ? OR contact_name ILIKE ?', "%#{q}%", "%#{q}%", "%#{q}%")
    }

    def display_name
      name
    end
  end
end
