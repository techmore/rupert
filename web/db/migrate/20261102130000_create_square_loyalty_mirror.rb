# frozen_string_literal: true

# A read-only local copy of the Square Loyalty program: the program and its reward
# tiers, promotions, member accounts and the points ledger. Rows are keyed by the
# Square ID per workspace, so a re-run updates in place and never duplicates.
class CreateSquareLoyaltyMirror < ActiveRecord::Migration[8.1]
  def change
    create_table :square_loyalty_programs do |t|
      t.string :tenant_id, null: false
      t.string :external_id, null: false
      t.string :status
      t.string :terminology_one
      t.string :terminology_other
      t.string :expiration_duration
      t.text :location_ids
      t.text :accrual_rules
      t.datetime :source_created_at
      t.datetime :source_updated_at
      t.datetime :last_seen_at, null: false
      t.timestamps
      t.index %i[tenant_id external_id], unique: true, name: 'idx_square_loyalty_program_source'
    end

    create_table :square_loyalty_reward_tiers do |t|
      t.string :tenant_id, null: false
      t.references :square_loyalty_program, null: false, index: false
      t.string :external_id, null: false
      t.string :name
      t.integer :points, null: false
      t.string :pricing_rule_object_id
      t.boolean :source_present, null: false, default: true
      t.datetime :source_created_at
      t.datetime :last_seen_at, null: false
      t.timestamps
      t.index %i[tenant_id external_id], unique: true, name: 'idx_square_loyalty_tier_source'
      t.index %i[tenant_id square_loyalty_program_id points], name: 'idx_square_loyalty_tier_program'
    end

    create_table :square_loyalty_promotions do |t|
      t.string :tenant_id, null: false
      t.references :square_loyalty_program, null: false, index: false
      t.string :external_id, null: false
      t.string :name
      t.string :status
      t.string :incentive_type
      t.integer :points_multiplier
      t.integer :points_addition
      t.bigint :minimum_spend_cents
      t.string :currency
      t.text :available_time
      t.text :trigger_limit
      t.text :qualifying_item_variation_ids
      t.text :qualifying_category_ids
      t.datetime :source_created_at
      t.datetime :source_updated_at
      t.datetime :canceled_at
      t.datetime :last_seen_at, null: false
      t.timestamps
      t.index %i[tenant_id external_id], unique: true, name: 'idx_square_loyalty_promotion_source'
    end

    create_table :square_loyalty_accounts do |t|
      t.string :tenant_id, null: false
      t.string :external_id, null: false
      t.string :program_external_id, null: false
      t.string :square_customer_id
      t.integer :balance, null: false, default: 0
      t.integer :lifetime_points, null: false, default: 0
      t.text :phone_number
      t.text :expiring_point_deadlines
      t.datetime :enrolled_at
      t.datetime :source_created_at
      t.datetime :source_updated_at
      t.boolean :source_present, null: false, default: true
      t.datetime :last_seen_at, null: false
      t.timestamps
      t.index %i[tenant_id external_id], unique: true, name: 'idx_square_loyalty_account_source'
      t.index %i[tenant_id square_customer_id], name: 'idx_square_loyalty_account_customer'
      t.index %i[tenant_id balance], name: 'idx_square_loyalty_account_balance'
    end

    create_table :square_loyalty_events do |t|
      t.string :tenant_id, null: false
      t.string :external_id, null: false
      t.string :loyalty_account_external_id, null: false
      t.string :event_type, null: false
      t.integer :points
      t.integer :points_change, null: false, default: 0
      t.string :order_id
      t.string :reward_id
      t.string :promotion_id
      t.string :reason
      t.string :location_id
      t.string :source
      t.datetime :occurred_at, null: false
      t.datetime :last_seen_at, null: false
      t.timestamps
      t.index %i[tenant_id external_id], unique: true, name: 'idx_square_loyalty_event_source'
      t.index %i[tenant_id loyalty_account_external_id occurred_at], name: 'idx_square_loyalty_event_account'
      t.index %i[tenant_id occurred_at], name: 'idx_square_loyalty_event_time'
    end
  end
end
