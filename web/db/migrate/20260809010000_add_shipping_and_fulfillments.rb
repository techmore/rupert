# frozen_string_literal: true

class AddShippingAndFulfillments < ActiveRecord::Migration[8.1]
  def change
    add_column(:orders, :shipping_name, :string)
    add_column(:orders, :shipping_address1, :string)
    add_column(:orders, :shipping_address2, :string)
    add_column(:orders, :shipping_city, :string)
    add_column(:orders, :shipping_province, :string)
    add_column(:orders, :shipping_zip, :string)
    add_column(:orders, :shipping_country, :string)
    add_column(:orders, :shipping_phone, :string)

    create_table(:fulfillments) do |t|
      t.string(:tenant_id, null: false)
      t.bigint(:order_id, null: false)
      t.string(:source, default: "manual", null: false)
      t.string(:source_fulfillment_id)
      t.string(:status, default: "pending", null: false)
      t.string(:tracking_company)
      t.string(:tracking_number)
      t.string(:tracking_url)
      t.datetime(:fulfilled_at)
      t.timestamps

      t.index([:order_id])
      t.index([:tenant_id, :order_id])
      t.index([:source, :source_fulfillment_id], unique: true)
    end
  end
end
