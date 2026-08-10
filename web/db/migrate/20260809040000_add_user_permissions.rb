# frozen_string_literal: true

class AddUserPermissions < ActiveRecord::Migration[8.1]
  def change
    create_table(:user_permissions) do |t|
      t.string(:tenant_id, null: false)
      t.bigint(:user_id, null: false)
      t.string(:permission, null: false)
      t.boolean(:enabled, default: true, null: false)
      t.timestamps

      t.index([:tenant_id, :user_id, :permission], unique: true)
      t.index([:tenant_id, :user_id])
    end
  end
end
