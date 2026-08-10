# frozen_string_literal: true

class AddDiscardedAt < ActiveRecord::Migration[8.1]
  def change
    add_column(:expenses, :discarded_at, :datetime)
    add_column(:vendor_payments, :discarded_at, :datetime)
    add_column(:refunds, :discarded_at, :datetime)

    add_index(:expenses, :discarded_at)
    add_index(:vendor_payments, :discarded_at)
    add_index(:refunds, :discarded_at)
  end
end
