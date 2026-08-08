# frozen_string_literal: true

class AddTenantAndPasswordToUsers < ActiveRecord::Migration[7.1]
  def change
    change_table :users do |t|
      t.string :tenant_id
      t.string :email
      t.string :password_digest
      t.string :name
      t.string :role, default: "admin"
      t.change_null :shopify_user_id, true
      t.change_null :shopify_domain, true
      t.change_null :shopify_token, true
    end
    add_index :users, :tenant_id
    add_index :users, :email, unique: true
  end
end
