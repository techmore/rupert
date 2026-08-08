# frozen_string_literal: true

module Core
  # Canonical customer record. Every sales channel (Shopify, Square POS,
  # manual walk-ins) upserts here keyed by (source, external_id) so CRM and
  # reports have one unified view of a person.
  class Customer < ApplicationRecord
    include TenantScoped

    self.table_name = "customers"

    SOURCES = ["shopify", "square", "pos", "manual"].freeze

    has_many :orders, class_name: "Core::Order", foreign_key: :customer_id

    validates :external_id, presence: true
    validates :source, inclusion: { in: SOURCES }

    scope :search, ->(term) do
      if term.present?
        where("first_name ILIKE :q OR last_name ILIKE :q OR email ILIKE :q OR phone ILIKE :q", q: "%#{term}%")
      end
    end

    class << self
      def ransackable_attributes(_auth_object = nil)
        ["first_name", "last_name", "email", "phone", "source", "created_at"]
      end

      def ransackable_associations(_auth_object = nil)
        ["orders"]
      end
    end

    def name
      [first_name, last_name].compact.join(" ").presence || email || phone || "Unnamed customer"
    end

    def lifetime_value_cents
      orders.sum(:gross_cents)
    end
  end
end
