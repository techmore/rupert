# frozen_string_literal: true

class CreateTenants < ActiveRecord::Migration[7.1]
  def change
    create_table :tenants, id: :string do |t|
      t.string :name, null: false
      t.string :subdomain, null: false
      t.string :status, default: "active"
      t.string :plan, default: "free"
      t.string :shopify_shop_domain
      t.timestamps
    end
    add_index :tenants, :subdomain, unique: true
  end
end
