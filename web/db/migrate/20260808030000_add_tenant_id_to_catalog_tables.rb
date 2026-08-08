# frozen_string_literal: true

class AddTenantIdToCatalogTables < ActiveRecord::Migration[7.1]
  TABLES = %w[
    ShopifyProduct ShopifyVariant SquareItem SquareVariation SkuLink
    ReconcileRun ReconcileItem Location InventoryLevel InventoryMovement
    StockAlert SyncRun InventoryPolicy LedgerEntry
  ].freeze

  def change
    TABLES.each do |table|
      add_column table, :tenant_id, :string unless column_exists?(table, :tenant_id)
      add_index table, :tenant_id unless index_exists?(table, :tenant_id)
    end
  end
end
