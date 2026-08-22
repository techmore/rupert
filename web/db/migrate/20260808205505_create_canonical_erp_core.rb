class CreateCanonicalErpCore < ActiveRecord::Migration[8.1]
  def change
    create_table :customers do |t|
      t.string :tenant_id, null: false
      t.string :first_name
      t.string :last_name
      t.string :email
      t.string :phone
      t.string :external_id, null: false
      t.string :source, null: false
      t.text :notes
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false

      t.index %i[tenant_id external_id source], unique: true
      t.index %i[tenant_id email]
      t.index %i[tenant_id phone]
    end

    create_table :orders do |t|
      t.string :tenant_id, null: false
      t.string :customer_id
      t.string :order_number
      t.string :source, null: false
      t.string :source_order_id, null: false
      t.string :channel
      t.string :location_id
      t.string :status, null: false
      t.string :currency, default: 'USD'
      t.integer :gross_cents, default: 0
      t.integer :tax_cents, default: 0
      t.integer :line_items, default: 0
      t.datetime :occurred_at, null: false
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false

      t.index %i[tenant_id source source_order_id], unique: true
      t.index %i[tenant_id occurred_at]
      t.index %i[tenant_id customer_id]
      t.index %i[tenant_id status]
    end

    create_table :order_lines do |t|
      t.string :tenant_id, null: false
      t.string :order_id, null: false
      t.string :sku
      t.string :name
      t.integer :quantity, default: 0
      t.integer :unit_cents, default: 0
      t.integer :line_cents, default: 0
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false

      t.index %i[tenant_id order_id]
      t.index %i[tenant_id sku]
    end

    create_table :payments do |t|
      t.string :tenant_id, null: false
      t.string :order_id, null: false
      t.string :method, null: false
      t.integer :amount_cents, default: 0
      t.string :status, default: 'completed'
      t.string :reference
      t.datetime :paid_at, null: false
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false

      t.index %i[tenant_id order_id]
      t.index %i[tenant_id paid_at]
    end
  end
end
