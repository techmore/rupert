# frozen_string_literal: true

# Append-only history for Square timecards: every source version Rupert has seen
# (not only the first and latest payloads on the card) and every manager decision
# on a changed or missing card, modelled on clock_corrections.
class CreateSquareTimecardHistory < ActiveRecord::Migration[8.1]
  def change
    create_table :square_timecard_versions do |t|
      t.string :tenant_id, null: false
      t.references :square_timecard, null: false, index: false
      t.string :kind, null: false
      t.string :digest
      t.text :payload
      t.integer :employee_id
      t.integer :source_version
      t.datetime :source_updated_at
      t.datetime :seen_at, null: false
      t.timestamps
      t.index %i[tenant_id square_timecard_id seen_at], name: 'idx_square_timecard_version_card'
      t.check_constraint "kind IN ('seen', 'missing')", name: 'square_timecard_version_kind'
    end

    create_table :square_timecard_reviews do |t|
      t.string :tenant_id, null: false
      t.references :square_timecard, null: false, index: false
      t.integer :reviewed_by_id
      t.string :decision, null: false
      t.text :reason, null: false
      t.string :status_before, null: false
      t.string :counted_digest
      t.string :latest_digest
      t.integer :employee_id_before
      t.integer :employee_id_after
      t.datetime :counted_started_at
      t.datetime :counted_ended_at
      t.bigint :counted_payable_seconds, null: false, default: 0
      t.datetime :latest_started_at
      t.datetime :latest_ended_at
      t.bigint :latest_payable_seconds
      t.text :held_by
      t.timestamps
      t.index %i[tenant_id square_timecard_id created_at], name: 'idx_square_timecard_review_card'
      t.index :reviewed_by_id
      t.check_constraint "decision IN ('accepted', 'kept', 'held')", name: 'square_timecard_review_decision'
    end

    # Digest (plus staff mapping) of a Square version a manager chose not to take, so the next
    # import does not flag the same edit again. 'missing' when they kept hours Square removed.
    safety_assured { add_column :square_timecards, :kept_source_key, :string }
  end
end
