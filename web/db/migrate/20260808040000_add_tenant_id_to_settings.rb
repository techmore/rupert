# frozen_string_literal: true

class AddTenantIdToSettings < ActiveRecord::Migration[7.1]
  def change
    add_column :settings, :tenant_id, :string
    remove_index :settings, :key
    add_index :settings, [:key, :tenant_id], unique: true
  end
end
