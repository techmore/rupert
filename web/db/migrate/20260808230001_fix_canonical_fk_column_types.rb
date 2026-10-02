# frozen_string_literal: true

class FixCanonicalFkColumnTypes < ActiveRecord::Migration[8.1]
  def up
    if connection.adapter_name.downcase.include?('postgres')
      change_column(:order_lines, :order_id, :bigint, using: 'order_id::bigint')
      change_column(:payments, :order_id, :bigint, using: 'order_id::bigint')
      change_column(:orders, :customer_id, :bigint, using: 'customer_id::bigint')
    else
      change_column(:order_lines, :order_id, :bigint)
      change_column(:payments, :order_id, :bigint)
      change_column(:orders, :customer_id, :bigint)
    end
  end

  def down
    change_column(:order_lines, :order_id, :string)
    change_column(:payments, :order_id, :string)
    change_column(:orders, :customer_id, :string)
  end
end
