# frozen_string_literal: true

class AddPaymentReconciliationCheckedAt < ActiveRecord::Migration[8.1]
  def change
    add_column :pos_payment_attempts, :reconciliation_checked_at, :datetime
  end
end
