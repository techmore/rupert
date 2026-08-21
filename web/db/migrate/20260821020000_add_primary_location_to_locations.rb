# frozen_string_literal: true

# Explicit primary flag per platform location. Shopify and Square are separate
# locations with independent inventories, so "which location is the one we sell
# from" must be deterministic instead of derived from sync order.
#
# The syncers set/clear this flag as locations come and go; Location.shopify_primary
# / square_primary prefer the flagged row and fall back to the legacy
# oldest-synced heuristic when nothing is flagged yet.
class AddPrimaryLocationToLocations < ActiveRecord::Migration[8.1]
  def change
    add_column :Location, :primary_location, :boolean, default: false, null: false
    add_index :Location, [:tenant_id, :source, :primary_location],
      name: "idx_locations_tenant_source_primary"
  end
end
