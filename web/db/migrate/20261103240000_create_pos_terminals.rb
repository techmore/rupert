# frozen_string_literal: true

# Extra Dejavoo terminals for a store: each has its own TPN and SPIn auth key
# and serves the register with the same name (or an event). Registers without
# one use the store's main TPN. A checkout remembers its terminal so refunds
# and batch close go back to the same one; terminals are retired, never deleted.
class CreatePosTerminals < ActiveRecord::Migration[8.1]
  def change
    create_table :pos_terminals do |t|
      t.string :tenant_id, null: false
      t.string :location_id, null: false
      t.string :name, null: false
      t.string :register_name, null: false
      t.text :credentials_json, null: false
      t.datetime :verified_at
      t.datetime :retired_at
      t.timestamps
    end
    add_index :pos_terminals, %i[tenant_id location_id]
    add_column :pos_checkouts, :pos_terminal_id, :bigint
  end
end
