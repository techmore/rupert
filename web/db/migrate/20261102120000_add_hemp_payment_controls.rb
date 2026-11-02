# frozen_string_literal: true

# F69: hemp/CBD card acceptance.
# - processor_catalogs / processor_catalog_entries: the per-processor allow-list of
#   SKUs and categories a processor approved. Only listed items can be charged on an
#   enforced processor.
# - pos_payment_attempts: receipt details (brand, last four, auth code) and a
#   cashier-safe decline reason. Never a card number.
# - pos_card_reversals: durable void/refund attempts, stored before the gateway call.
# - pos_settings: owner sign-off for a production NMI account, and a webhook
#   signing key (Authorize.net Signature Key or NMI signing key).
class AddHempPaymentControls < ActiveRecord::Migration[8.1]
  def change
    create_table :processor_catalogs do |t|
      t.string :tenant_id, null: false
      t.string :processor, null: false
      t.boolean :enforced, null: false, default: false
      t.string :approval_reference
      t.text :approval_note
      t.integer :approved_by_id
      t.datetime :approved_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index %i[tenant_id processor], unique: true
      t.check_constraint "processor IN ('authorize_net', 'nmi', 'card_terminal')", name: 'processor_catalog_processor'
    end

    create_table :processor_catalog_entries do |t|
      t.string :tenant_id, null: false
      t.references :processor_catalog, null: false, index: false
      t.string :kind, null: false
      t.string :value, null: false
      t.string :normalized_value, null: false
      t.integer :added_by_id
      t.timestamps
      t.index %i[processor_catalog_id kind normalized_value], unique: true, name: 'idx_processor_catalog_entry_value'
      t.check_constraint "kind IN ('sku', 'category', 'excluded_sku')", name: 'processor_catalog_entry_kind'
    end

    add_column :pos_payment_attempts, :card_brand, :string
    add_column :pos_payment_attempts, :card_last_four, :string
    add_column :pos_payment_attempts, :auth_code, :string
    add_column :pos_payment_attempts, :decline_reason, :string

    create_table :pos_card_reversals do |t|
      t.string :tenant_id, null: false
      t.references :pos_checkout, null: false
      t.references :pos_payment_attempt, null: false, index: false
      t.string :kind, null: false
      t.string :status, null: false, default: 'submitting'
      t.string :reference, null: false
      t.integer :amount_cents, null: false
      t.string :transaction_id
      t.text :reason
      t.string :failure_message
      t.integer :requested_by_id, null: false
      t.integer :core_refund_id
      t.datetime :submitted_at, null: false
      t.datetime :resolved_at
      t.timestamps
      t.index :reference, unique: true
      t.check_constraint "kind IN ('void', 'refund')", name: 'pos_card_reversal_kind'
      t.check_constraint "status IN ('submitting', 'unknown', 'succeeded', 'failed')", name: 'pos_card_reversal_status'
      t.check_constraint 'amount_cents > 0', name: 'pos_card_reversal_amount'
    end

    add_column :pos_settings, :production_approved_at, :datetime
    add_column :pos_settings, :production_approved_by_id, :integer
    add_column :pos_settings, :production_approval_note, :text
    # Encrypted by the model. Verifies gateway webhooks; never sent anywhere.
    add_column :pos_settings, :webhook_signing_key, :text
  end
end
