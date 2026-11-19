# frozen_string_literal: true

# Self-service subscriptions (RUPERT_SELF_SERVICE, off by default; docs/ops/self-service-billing.md).
# Additive only: one defaulted column on tenants, nullable/defaulted columns on customer_subscriptions,
# and one new table. No existing value is changed and nothing is dropped.
#
# tenants.billing_exempt defaults to TRUE, so every workspace that exists when this runs, and every
# workspace created later by any path other than self-service sign-up, is exempt from subscription
# checks. Only a self-service registration (or the operator, deliberately) creates a billable workspace.
class AddSelfServiceBilling < ActiveRecord::Migration[8.1]
  def change
    # SQLite adds a column with a constant default without rewriting rows; both tables are small
    # (one row per workspace) and the app is single-writer.
    safety_assured do
      add_column :tenants, :billing_exempt, :boolean, default: true, null: false
      add_column :customer_subscriptions, :cancel_at_period_end, :boolean, default: false, null: false
    end
    add_column :customer_subscriptions, :trial_ends_at, :datetime
    add_column :customer_subscriptions, :past_due_since, :datetime
    add_column :customer_subscriptions, :current_period_end, :datetime
    add_column :customer_subscriptions, :comp_until, :datetime
    add_column :customer_subscriptions, :comp_note, :string
    add_column :customer_subscriptions, :signup_terms_version, :string
    add_column :customer_subscriptions, :signup_terms_accepted_at, :datetime

    # One row per Stripe event id: a redelivered event is acknowledged without being applied twice.
    # Holds the event's id, type and timestamps only, never its payload.
    create_table :billing_webhook_events do |t|
      t.string :stripe_event_id, null: false
      t.string :event_type, null: false
      t.datetime :event_created_at
      t.datetime :processed_at
      t.integer :deliveries, default: 1, null: false
      t.timestamps
      t.index :stripe_event_id, unique: true
    end
  end
end
