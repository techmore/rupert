# frozen_string_literal: true

class CreatePurchasing < ActiveRecord::Migration[8.1]
  def change
    create_table(:vendors) do |t|
      t.string(:tenant_id, null: false)
      t.string(:name, null: false)
      t.string(:email)
      t.string(:phone)
      t.string(:contact_name)
      t.text(:address)
      t.text(:notes)
      t.string(:payment_terms, default: 'net30')
      t.timestamps

      t.index(%i[tenant_id name], unique: true)
    end

    create_table(:purchase_orders) do |t|
      t.string(:tenant_id, null: false)
      t.bigint(:vendor_id, null: false)
      t.string(:order_number, null: false)
      t.string(:status, null: false, default: 'draft')
      t.date(:expected_date)
      t.date(:received_date)
      t.text(:notes)
      t.timestamps

      t.index(%i[tenant_id vendor_id])
      t.index(%i[tenant_id order_number], unique: true)
      t.index(%i[tenant_id status])
    end

    create_table(:purchase_order_lines) do |t|
      t.string(:tenant_id, null: false)
      t.bigint(:purchase_order_id, null: false)
      t.string(:sku)
      t.string(:name, null: false)
      t.integer(:quantity, null: false, default: 1)
      t.integer(:unit_cost_cents, null: false, default: 0)
      t.integer(:received_quantity, null: false, default: 0)
      t.timestamps

      t.index(%i[tenant_id purchase_order_id])
      t.index(%i[tenant_id sku])
    end
  end
end
