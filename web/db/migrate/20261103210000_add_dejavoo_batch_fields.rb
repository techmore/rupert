# frozen_string_literal: true

# Dejavoo terminal sales and refunds remember their SPIn batch and card type
# (credit/debit), so a closed batch can be matched to Rupert's own records and
# a refund uses the same card type. Nullable: older rows and other gateways
# leave them empty.
class AddDejavooBatchFields < ActiveRecord::Migration[8.1]
  def change
    add_column :pos_payment_attempts, :batch_number, :string
    add_column :pos_payment_attempts, :payment_type, :string
    add_column :pos_card_reversals, :batch_number, :string
  end
end
