# frozen_string_literal: true

# What was on each 1099 when it was issued (#472): one row per original or corrected form, never changed afterwards.
class CreateTaxFormFilings < ActiveRecord::Migration[8.1]
  def change
    create_table :tax_form_filings do |t|
      t.string :tenant_id, null: false
      t.references :tax_payee, null: false, foreign_key: true
      t.integer :tax_year, null: false
      t.string :kind, null: false
      t.string :form_type, null: false
      t.string :misc_box
      t.bigint :paid_cents, null: false
      t.string :legal_name, null: false
      t.string :tin_last4
      t.integer :issued_by_id
      t.string :issued_by_name
      t.datetime :issued_at, null: false
      t.timestamps
    end
    add_index :tax_form_filings, %i[tenant_id tax_year tax_payee_id], name: 'index_tax_form_filings_on_tenant_year_payee'
  end
end
