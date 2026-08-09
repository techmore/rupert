# frozen_string_literal: true

class AddEmployeesAndRolePermissions < ActiveRecord::Migration[8.1]
  def change
    add_column(:users, :active, :boolean, default: true, null: false)

    create_table(:role_permissions) do |t|
      t.string(:tenant_id, null: false)
      t.string(:role, null: false)
      t.string(:permission, null: false)
      t.boolean(:enabled, default: true, null: false)
      t.timestamps

      t.index([:tenant_id, :role, :permission], unique: true)
      t.index([:tenant_id, :role])
    end
  end
end
