# frozen_string_literal: true

# Shared work items, phase 1 (#407 #413). The `tasks` table becomes the one shared table for tracked work: every
# row gets a `kind` ('task' for all existing rows) plus the columns every kind shares (requester, started time,
# parent item, a polymorphic source link and a JSON `details` document for kind-specific fields). `Work::Item`
# reads every kind; `Projects::Task` keeps reading only `kind = 'task'`.
#
# The table is NOT renamed. Auto-deploy runs db:migrate before the restart and does not revert migrations when it
# rolls code back, so a rename would break the running (and the rolled-back) code. Every change here is additive:
# the previous release ignores the new columns and keeps working. No rows are copied or rewritten, so task ids,
# URLs and every foreign key that points at tasks (checklists, comments, time, files, dependencies, assistant
# requests) stay exactly as they are.
#
# `work_item_events` is the append-only history every kind writes to. It has no foreign key to tasks on purpose:
# a deleted item's history outlives it.
#
# Rollback: `down` drops the history table and the added columns (refused while rows of another kind exist);
# task data in the original columns is untouched.
# See docs/architecture/shared-work-items.md.
class MakeTasksSharedWorkItems < ActiveRecord::Migration[8.1]
  # SQLite must switch foreign_keys OFF before its rollback transaction (the rollback rebuilds `tasks`, which six
  # tables point at). Rails' outer DDL transaction would otherwise make that PRAGMA ineffective.
  disable_ddl_transaction!

  NEW_COLUMNS = %i[details source_id source_type parent_id started_at requester_id kind].freeze

  def up
    connection.transaction do
      # SQLite stores a constant default in the table definition: existing rows read 'task' at once, with no
      # rewrite and no backfill, so a NOT NULL column with a default is safe here (the strong_migrations advice
      # for this is about PostgreSQL table rewrites).
      safety_assured { add_column :tasks, :kind, :string, null: false, default: 'task' }
      add_column :tasks, :requester_id, :string
      add_column :tasks, :started_at, :datetime
      add_column :tasks, :parent_id, :bigint
      add_column :tasks, :source_type, :string
      add_column :tasks, :source_id, :bigint
      add_column :tasks, :details, :text
      add_index :tasks, %i[tenant_id kind status], name: 'index_tasks_on_tenant_kind_status'
      add_index :tasks, %i[tenant_id parent_id], name: 'index_tasks_on_tenant_parent'
      add_index :tasks, %i[source_type source_id], name: 'index_tasks_on_source'
      create_work_item_events
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Run this SQLite rollback outside an existing transaction.' if connection.transaction_open?
    if select_value("SELECT COUNT(*) FROM tasks WHERE kind <> 'task'").to_i.positive?
      raise ActiveRecord::IrreversibleMigration, 'Work items of other kinds exist; move or remove them before rolling back.'
    end

    connection.disable_referential_integrity do
      connection.transaction do
        drop_table :work_item_events
        remove_index :tasks, name: 'index_tasks_on_source'
        remove_index :tasks, name: 'index_tasks_on_tenant_parent'
        remove_index :tasks, name: 'index_tasks_on_tenant_kind_status'
        safety_assured { NEW_COLUMNS.each { |column| remove_column :tasks, column } }
      end
    end
  end

  private

  def create_work_item_events
    create_table :work_item_events do |t|
      t.string :tenant_id, null: false
      t.bigint :work_item_id, null: false
      t.string :item_kind, null: false
      t.string :action, null: false
      t.string :transition
      t.string :from_status
      t.string :to_status
      t.bigint :actor_id
      t.string :actor_name, null: false
      t.text :field_changes
      t.string :note
      t.datetime :created_at, null: false
    end
    add_index :work_item_events, %i[tenant_id work_item_id created_at], name: 'idx_work_item_events_timeline'
    add_index :work_item_events, %i[tenant_id item_kind created_at], name: 'idx_work_item_events_by_kind'
  end
end
