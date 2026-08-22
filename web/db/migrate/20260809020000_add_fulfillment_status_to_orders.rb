# frozen_string_literal: true

class AddFulfillmentStatusToOrders < ActiveRecord::Migration[8.1]
  def change
    add_column(:orders, :fulfillment_status, :string, default: 'pending', null: false)
  end
end
