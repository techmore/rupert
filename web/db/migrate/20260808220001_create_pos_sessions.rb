class CreatePosSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :pos_sessions do |t|
      t.string :tenant_id, null: false
      t.string :user_id
      t.string :location_id
      t.string :name, null: false
      t.datetime :opened_at, null: false
      t.datetime :closed_at
      t.integer :opening_cash_cents, default: 0
      t.integer :cash_sales_cents, default: 0
      t.integer :card_sales_cents, default: 0
      t.integer :gift_sales_cents, default: 0
      t.integer :counted_cash_cents
      t.integer :expected_cash_cents
      t.integer :variance_cents
      t.string :status, default: "open", null: false
      t.text :notes
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false

      t.index [:tenant_id, :status]
      t.index [:tenant_id, :opened_at]
    end
  end
end
