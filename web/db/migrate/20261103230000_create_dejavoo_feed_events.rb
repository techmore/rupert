# frozen_string_literal: true

# Transactions and settlements pushed by Dejavoo FEED, so every sale, refund
# and batch the terminal or online page processes reaches Rupert, including
# ones run outside Rupert. Only non-sensitive fields are kept: no card number,
# cardholder name, email, phone or card token.
class CreateDejavooFeedEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :dejavoo_feed_events do |t|
      t.string :tenant_id, null: false
      t.references :pos_setting, null: false
      t.string :feed_id, null: false
      t.string :request_type, null: false
      t.string :event_type, null: false
      t.string :sub_event_type
      t.string :tpn
      t.string :transaction_id
      t.string :external_reference_id
      t.string :rrn
      t.string :original_rrn
      t.string :batch_number
      t.string :source_type
      t.string :card_label
      t.string :card_last_four
      t.string :approval_code
      t.string :host_response_code
      t.integer :amount_cents
      t.integer :tip_cents
      t.integer :settlement_count
      t.integer :settlement_cents
      t.string :occurred_on
      t.string :matched_kind
      t.bigint :matched_id
      t.datetime :received_at, null: false
      t.timestamps
    end
    add_index :dejavoo_feed_events, %i[tenant_id feed_id], unique: true
    add_index :dejavoo_feed_events, %i[tenant_id external_reference_id]
    add_index :dejavoo_feed_events, %i[pos_setting_id received_at]
  end
end
