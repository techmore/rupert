class CreateInventoryCounts < ActiveRecord::Migration[8.1]
  def change
    create_table 'InventoryCount', id: :string do |t|
      t.string 'status', default: 'draft', null: false
      t.string 'locationId'
      t.string 'note'
      t.string 'createdBy'
      t.string 'tenant_id'
      t.datetime 'countedAt', null: false
      t.datetime 'approvedAt'
      t.datetime 'appliedAt'
    end
    add_index 'InventoryCount', %w[tenant_id countedAt]

    create_table 'InventoryCountItem', id: :string do |t|
      t.string 'countId', null: false
      t.string 'sku', null: false
      t.string 'shopifyVariantId'
      t.string 'squareVariationId'
      t.integer 'quantity', default: 0, null: false
      t.integer 'previousQuantity'
      t.boolean 'applied', default: false, null: false
      t.string 'tenant_id'
    end
    add_index 'InventoryCountItem', ['countId']
    add_index 'InventoryCountItem', ['tenant_id']
  end
end
