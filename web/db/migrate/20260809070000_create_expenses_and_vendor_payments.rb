# frozen_string_literal: true

class CreateExpensesAndVendorPayments < ActiveRecord::Migration[8.1]
  def change
    create_table(:expenses) do |t|
      t.string(:tenant_id, null: false)
      t.bigint(:vendor_id)
      t.string(:category, null: false, default: 'other')
      t.string(:payee)
      t.integer(:amount_cents, null: false, default: 0)
      t.date(:incurred_on, null: false)
      t.string(:method, default: 'card')
      t.string(:reference)
      t.text(:notes)
      t.timestamps

      t.index(%i[tenant_id incurred_on])
      t.index(%i[tenant_id category])
    end

    create_table(:vendor_payments) do |t|
      t.string(:tenant_id, null: false)
      t.bigint(:vendor_id, null: false)
      t.integer(:amount_cents, null: false, default: 0)
      t.date(:paid_on, null: false)
      t.string(:method, default: 'check')
      t.string(:reference)
      t.text(:notes)
      t.timestamps

      t.index(%i[tenant_id vendor_id])
      t.index(%i[tenant_id paid_on])
    end
  end
end
