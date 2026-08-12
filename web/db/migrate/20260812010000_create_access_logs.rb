# frozen_string_literal: true

class CreateAccessLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :access_logs do |t|
      t.string :tenant_id
      t.bigint :user_id
      t.string :email
      t.string :source
      t.string :status
      t.string :ip
      t.string :user_agent
      t.string :detail
      t.timestamps
    end
    add_index :access_logs, :tenant_id
    add_index :access_logs, [:tenant_id, :created_at]
    add_index :access_logs, [:tenant_id, :status]
  end
end
