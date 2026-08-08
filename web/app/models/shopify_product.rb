# frozen_string_literal: true

class ShopifyProduct < ApplicationRecord
  include TenantScoped

  self.table_name = "ShopifyProduct"
  self.primary_key = "id"

  has_many :variants, class_name: "ShopifyVariant", foreign_key: "productId",
    dependent: :destroy, inverse_of: :product

  scope :active, -> { where(status: "ACTIVE") }
  scope :search, ->(q) {
    return all if q.blank?
    where(title: q).or(where("title LIKE ?", "%#{q}%"))
  }
end
