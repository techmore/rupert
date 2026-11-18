# frozen_string_literal: true

# How the card was presented (tap, chip, swipe, keyed or unknown; PaymentEntryMethod),
# for receipts and reconciliation. Additive only: two nullable columns with no default,
# which SQLite adds without rewriting either table. No backfill and no data change, so
# every existing row stays NULL ("not recorded"). The fixed list is enforced by the
# models; a CHECK constraint would need a table rebuild.
class AddEntryMethodToCardPayments < ActiveRecord::Migration[8.1]
  def change
    add_column :pos_payment_attempts, :entry_method, :string
    add_column :payments, :entry_method, :string
  end
end
