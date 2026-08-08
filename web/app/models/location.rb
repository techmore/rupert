# frozen_string_literal: true

class Location < ApplicationRecord
  include HasCuid

  self.table_name = "Location"
  self.primary_key = "id"

  has_many :levels, class_name: "InventoryLevel", foreign_key: "locationId",
    dependent: :destroy

  scope :by_source, ->(source) { where(source: source) }
end
