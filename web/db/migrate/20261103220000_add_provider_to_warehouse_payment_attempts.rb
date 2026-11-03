# frozen_string_literal: true

# Online checkout can pay through Dejavoo's Hosted Payment Page as well as
# Authorize.net. Existing attempts are Authorize.net; hosted_url (encrypted)
# lets a shopper return to an unfinished Dejavoo payment page.
class AddProviderToWarehousePaymentAttempts < ActiveRecord::Migration[8.1]
  def change
    # SQLite, a small table: the constant default needs no staged backfill.
    safety_assured { add_column :warehouse_payment_attempts, :provider, :string, null: false, default: 'authorize_net' }
    add_column :warehouse_payment_attempts, :hosted_url, :text
  end
end
