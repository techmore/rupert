# frozen_string_literal: true

class CreateChartOfAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table(:accounts) do |t|
      t.string(:tenant_id, null: false)
      t.string(:code, null: false)
      t.string(:name, null: false)
      t.string(:account_type, null: false)
      t.string(:normal_balance, null: false)
      t.text(:description)
      t.boolean(:active, null: false, default: true)
      t.timestamps

      t.index(%i[tenant_id code], unique: true)
      t.index(%i[tenant_id account_type])
    end
  end
end
