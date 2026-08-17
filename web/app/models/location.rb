# frozen_string_literal: true

class Location < ApplicationRecord
  include HasCuid
  include TenantScoped

  self.table_name = "Location"
  self.primary_key = "id"

  has_many :levels,
    class_name: "InventoryLevel",
    foreign_key: "locationId",
    dependent: :destroy

  scope :by_source, ->(source) { where(source: source) }

  # The app's primary Shopify / Square locations. Several writers need the
  # canonical location when pushing inventory adjustments; centralizes it.
  def self.shopify_primary
    by_source("shopify").order(:syncedAt).first
  end

  def self.square_primary
    by_source("square").order(:syncedAt).first
  end
end
