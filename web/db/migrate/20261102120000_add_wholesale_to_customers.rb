# frozen_string_literal: true

# Rupert-only wholesale annotations. Directory syncs and order imports never
# write these columns, and nothing here is sent back to Shopify or Square.
# SQLite adds a column with a constant default without rewriting rows.
class AddWholesaleToCustomers < ActiveRecord::Migration[8.1]
  def change
    safety_assured { add_column :customers, :wholesale, :boolean, null: false, default: false }
    add_column :customers, :wholesale_business_name, :string
    add_column :customers, :resale_certificate_number, :string
    add_column :customers, :resale_certificate_expires_on, :date
    add_column :customers, :wholesale_notes, :text
    add_index :customers, %i[tenant_id wholesale]
  end
end
