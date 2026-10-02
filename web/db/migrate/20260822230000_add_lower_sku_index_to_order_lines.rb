# frozen_string_literal: true

# The restock advisor and ledger queries match SKUs case-insensitively
# (LOWER(sku) IN (...)), which can't use the plain btree index. This functional
# index lets PostgreSQL use an index scan for those lookups instead of
# filtering every row after a fetch.
class AddLowerSkuIndexToOrderLines < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :order_lines, 'tenant_id, lower(sku)',
              name: 'index_order_lines_on_tenant_id_and_lower_sku',
              algorithm: :concurrently
  end
end
