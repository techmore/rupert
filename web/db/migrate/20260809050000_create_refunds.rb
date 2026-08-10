# frozen_string_literal: true

class CreateRefunds < ActiveRecord::Migration[8.1]
  def change
    create_table(:refunds) do |t|
      t.string(:tenant_id, null: false)
      t.bigint(:order_id, null: false)
      t.integer(:amount_cents, null: false, default: 0)
      t.string(:method, null: false, default: "card")
      t.string(:reason)
      t.string(:reference)
      t.datetime(:refunded_at, null: false)
      t.timestamps

      t.index([:tenant_id, :order_id])
      t.index([:tenant_id, :refunded_at])
    end
  end
end
