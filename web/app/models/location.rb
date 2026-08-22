# frozen_string_literal: true

class Location < ApplicationRecord
  include HasCuid
  include TenantScoped

  self.table_name = 'Location'
  self.primary_key = 'id'

  has_many :levels,
           class_name: 'InventoryLevel',
           foreign_key: 'locationId',
           dependent: :destroy

  scope :by_source, ->(source) { where(source: source) }

  # The app's primary Shopify / Square locations. Several writers need the
  # canonical location when pushing inventory adjustments; centralizes it.
  #
  # Resolution order: the location the syncer flagged as primary_location,
  # then the legacy heuristic (oldest-synced row for that source). The flag is
  # maintained by CatalogSyncer/SquareSyncer as locations come and go.
  def self.shopify_primary
    primary_for('shopify')
  end

  def self.square_primary
    primary_for('square')
  end

  def self.primary_for(source)
    by_source(source).where(primary_location: true).order(:syncedAt).first ||
      by_source(source).order(:syncedAt).first
  end
end
