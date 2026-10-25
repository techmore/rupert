# frozen_string_literal: true

# Observed redemptions and results of marketing events (#415). Results are facts, not work, so they sit beside the
# shared work-item table (docs/architecture/shared-work-items.md), one row per event, discount code, order source,
# store location and currency. That identity is unique, so the same redemptions cannot be stored twice for an event,
# and the orders a row counted are kept (order_ids) so no order is attributed to two events.
class CreateMarketingResults < ActiveRecord::Migration[8.1]
  def change
    create_table :marketing_results do |t|
      t.string :tenant_id, null: false
      t.bigint :work_item_id, null: false
      t.bigint :offer_id
      t.string :code, null: false, default: ''
      t.string :basis, null: false
      t.string :order_source, null: false, default: ''
      t.string :location_id, null: false, default: ''
      t.string :currency, null: false, default: 'USD'
      t.datetime :window_starts_at
      t.datetime :window_ends_at
      t.integer :redemptions, null: false, default: 0
      t.bigint :revenue_cents, null: false, default: 0
      t.text :order_ids
      t.text :summary
      t.bigint :recorded_by_id
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :marketing_results, %i[tenant_id work_item_id code order_source location_id currency], unique: true,
      name: 'idx_marketing_results_identity'
    add_index :marketing_results, %i[tenant_id code], name: 'idx_marketing_results_code'
  end
end
