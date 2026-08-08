# frozen_string_literal: true

class SquareItem < ApplicationRecord
  include TenantScoped

  self.table_name = "SquareItem"
  self.primary_key = "id"

  has_many :variations,
    class_name: "SquareVariation",
    foreign_key: "itemId",
    dependent: :destroy,
    inverse_of: :item
end
