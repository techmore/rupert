# frozen_string_literal: true

# Owner-made training (#399 #410 #411): a module (text, files, a video link), its assignments to people with a due
# date and state (assigned → in progress → completed, or cancelled), and an append-only history of every change.
#
# Shaped to fold into the shared Project table later (#407 #409): an assignment carries the same columns a task does
# (tenant_id, assignee_id, due_on, status, started/completed timestamps) and the history rows are generic
# (actor, action, from/to status, created_at). Files follow the Upload convention: bytes encrypted in the database,
# so the normal database backups carry them.
class CreateTrainingAssignments < ActiveRecord::Migration[8.1]
  def change
    create_table :training_modules do |t|
      t.string :tenant_id, null: false
      t.string :title, null: false
      t.text :body
      t.string :video_url
      t.integer :revision, null: false, default: 1
      t.bigint :created_by_id
      t.bigint :updated_by_id
      t.timestamps
    end
    add_index :training_modules, %i[tenant_id title]

    create_table :training_attachments do |t|
      t.string :tenant_id, null: false
      t.references :training_module, null: false, foreign_key: true
      t.bigint :uploaded_by_id
      t.string :filename, null: false
      t.string :content_type, null: false
      t.integer :byte_size, null: false
      t.string :sha256, null: false
      t.text :content_base64, null: false
      t.datetime :removed_at
      t.bigint :removed_by_id
      t.timestamps
    end
    add_index :training_attachments, %i[tenant_id training_module_id]

    create_table :training_assignments do |t|
      t.string :tenant_id, null: false
      t.references :training_module, null: false, foreign_key: true
      t.bigint :assignee_id, null: false
      t.bigint :assigned_by_id
      t.date :due_on
      t.string :status, null: false, default: 'assigned'
      t.datetime :started_at
      t.datetime :completed_at
      t.bigint :completed_by_id
      t.integer :completed_revision
      t.datetime :cancelled_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :training_assignments, %i[tenant_id assignee_id status], name: 'idx_training_assignments_by_assignee'
    add_index :training_assignments, %i[tenant_id training_module_id status], name: 'idx_training_assignments_by_module'

    create_table :training_assignment_events do |t|
      t.string :tenant_id, null: false
      t.references :training_assignment, null: false, foreign_key: true
      t.bigint :actor_id
      t.string :actor_name, null: false
      t.string :action, null: false
      t.string :from_status
      t.string :to_status, null: false
      t.integer :module_revision, null: false
      t.string :note
      t.datetime :created_at, null: false
    end
    add_index :training_assignment_events, %i[tenant_id training_assignment_id created_at], name: 'idx_training_assignment_events_timeline'
  end
end
