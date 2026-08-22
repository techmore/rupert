# frozen_string_literal: true

# Heals mirror rows written with NULL tenant_id. The syncers used plain
# #upsert/#upsert_all, which skip callbacks — so TenantScoped's assign_tenant
# never ran and every synced ShopifyProduct/ShopifyVariant/SquareItem/
# SquareVariation/LedgerEntry row landed with a NULL tenant. Reads are
# default-scoped to Current.tenant_id, so those rows were invisible to the app
# (and NULLs defeat the tenant-inclusive unique indexes on InventoryLevel).
#
# When exactly one tenant exists (this deployment), claim the orphaned rows.
# With multiple tenants the mapping is unknowable here, so nothing changes.
class BackfillMirrorTenantIds < ActiveRecord::Migration[8.1]
  MIRROR_TABLES = %w[
    ShopifyProduct
    ShopifyVariant
    SquareItem
    SquareVariation
    LedgerEntry
    InventoryLevel
    InventoryMovement
  ].freeze

  def up
    tenant = execute('SELECT id FROM tenants ORDER BY created_at LIMIT 2').to_a
    return unless tenant.length == 1

    tenant_id = tenant.first['id']
    MIRROR_TABLES.each do |table|
      execute <<~SQL.squish
        UPDATE "#{table}" SET "tenant_id" = '#{tenant_id}' WHERE "tenant_id" IS NULL
      SQL
    end
  end

  def down
    # Irreversible data healing; nothing to restore.
  end
end
