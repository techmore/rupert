# frozen_string_literal: true

class CreateBankConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :bank_connections do |t|
      t.string :tenant_id, null: false
      t.string :environment, null: false, default: 'sandbox'
      t.text :credentials_json
      t.text :access_token
      t.string :item_id
      t.text :cursor
      t.boolean :sync_enabled, null: false, default: false
      t.datetime :last_synced_at
      t.string :last_error_code
      t.timestamps
    end
    add_index :bank_connections, :tenant_id, unique: true
    create_table :bank_feed_entries do |t|
      t.string :tenant_id, null: false
      t.references :bank_connection, null: false, foreign_key: true
      t.string :source_key, null: false
      t.text :payload_json
      t.bigint :bank_statement_line_id
      t.string :source_state, null: false, default: 'active'
      t.timestamps
    end
    add_index :bank_feed_entries, [:bank_connection_id, :source_key], unique: true
    add_index :bank_feed_entries, :tenant_id
    add_index :bank_feed_entries, :bank_statement_line_id, unique: true
    add_column :bank_statement_lines, :source_state, :string, default: 'active', null: false
  end
end
