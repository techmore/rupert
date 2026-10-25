# frozen_string_literal: true

require 'test_helper'
require_relative '../../db/migrate/20261026150900_move_training_assignments_to_work_items'

# Moving training assignments into the shared work-item table (#409) on a copy of the tables with rows in them:
# every assignment and history row is copied once with everything it held, the old tables are left exactly as they
# were, a second run copies nothing new, rows the previous release wrote after the copy are picked up by a re-run,
# a count mismatch stops the copy, and down/up work.
class TrainingWorkItemsMigrationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class IsolatedDatabase < ActiveRecord::Base
    self.abstract_class = true
  end

  VERSION = 20261026150900
  Migration = MoveTrainingAssignmentsToWorkItems
  OLD_TABLES = %w[training_modules training_assignments training_assignment_events].freeze

  setup do
    # A separate in-memory pool: never rebuild the application test database or its fixture tables.
    IsolatedDatabase.establish_connection(adapter: 'sqlite3', database: ':memory:')
    @pool = IsolatedDatabase.connection_pool
    @connection = @pool.lease_connection
    build_tables
    ActiveRecord::Tasks::DatabaseTasks.stubs(:migration_connection).returns(@connection)
    ActiveRecord::Tasks::DatabaseTasks.stubs(:migration_connection_pool).returns(@pool)
    @before = snapshot
  end

  teardown do
    @pool&.disconnect!
    IsolatedDatabase.remove_connection
  end

  test 'up copies every assignment and event with everything it held, and keeps the old tables as they were' do
    run_migration(:up)
    assert_equal @before, snapshot
    assert_equal 5, value("SELECT COUNT(*) FROM tasks WHERE kind = 'training_assignment'")
    assert_equal 3, value("SELECT COUNT(*) FROM tasks WHERE kind = 'task'")
    assert_equal 9, value("SELECT COUNT(*) FROM work_item_events WHERE item_kind = 'training_assignment'")
    assert_equal 0, value('SELECT COUNT(*) FROM training_assignments WHERE work_item_id IS NULL')

    completed = item_for(3)
    assert_equal ['t1', 'completed', '7', '9', '2026-10-20', 'TrainingModule', 1, 'Opening the store'],
      completed.values_at('tenant_id', 'status', 'assignee_id', 'requester_id', 'due_on', 'source_type', 'source_id', 'title')
    assert_equal({ 'legacy_id' => 3, 'completed_revision' => 2, 'completed_by_id' => 7 }, JSON.parse(completed['details']))
    assert_equal ['2026-10-02 09:00:00', '2026-10-03 10:00:00', '2026-10-01 08:00:00', '2026-10-03 10:00:00'],
      completed.values_at('started_at', 'completed_at', 'created_at', 'updated_at').map { |time| time.to_s.first(19) }
    cancelled = item_for(4)
    assert_equal ['cancelled', '2026-10-04 11:00:00'], [cancelled['status'], cancelled['completed_at'].to_s.first(19)]
    other = item_for(5)
    assert_equal ['t2', 'Their module', nil], [other['tenant_id'], other['title'], other['requester_id']]

    events = @connection.select_all("SELECT * FROM work_item_events WHERE work_item_id = #{completed['id']} ORDER BY created_at, id").to_a
    assert_equal [['created', nil, nil, 'assigned'], %w[transitioned start assigned in_progress], %w[transitioned complete in_progress completed]],
      events.map { |row| row.values_at('action', 'transition', 'from_status', 'to_status') }
    assert_equal [[9, 'Mona Manager'], [7, 'Sam Staff'], [7, 'Sam Staff']], events.map { |row| row.values_at('actor_id', 'actor_name') }
    assert_equal [1, 1, 2], events.map { |row| JSON.parse(row['details'])['module_revision'] }
    note = @connection.select_value("SELECT note FROM work_item_events WHERE work_item_id = #{cancelled['id']} AND transition = 'cancel'")
    assert_equal 'Wrong person', note

    # Running the copy again finds nothing to do.
    assert_equal({ assignments: 0, events: 0, refreshed: 0 }, Migration::Copy.run!(@connection))
    assert_equal 5, value("SELECT COUNT(*) FROM tasks WHERE kind = 'training_assignment'")
  end

  test 'a re-run picks up what the previous release wrote to the old tables after the copy' do
    run_migration(:up)
    # The previous release (after a code rollback) starts assignment 1 and assigns a new one.
    @connection.execute("UPDATE training_assignments SET status = 'in_progress', started_at = '2026-11-01 09:00:00', updated_at = '2026-11-01 09:00:00' WHERE id = 1")
    @connection.execute(<<~SQL.squish)
      INSERT INTO training_assignment_events (id, tenant_id, training_assignment_id, actor_id, actor_name, action, from_status, to_status, module_revision, created_at)
      VALUES (20, 't1', 1, 8, 'Cora', 'started', 'assigned', 'in_progress', 3, '2026-11-01 09:00:00')
    SQL
    @connection.execute(<<~SQL.squish)
      INSERT INTO training_assignments (id, tenant_id, training_module_id, assignee_id, assigned_by_id, status, created_at, updated_at)
      VALUES (6, 't1', 2, 8, 9, 'assigned', '2026-11-01 10:00:00', '2026-11-01 10:00:00')
    SQL
    @connection.execute(<<~SQL.squish)
      INSERT INTO training_assignment_events (id, tenant_id, training_assignment_id, actor_id, actor_name, action, to_status, module_revision, created_at)
      VALUES (21, 't1', 6, 9, 'Mona Manager', 'assigned', 'assigned', 1, '2026-11-01 10:00:00')
    SQL

    assert_equal({ assignments: 1, events: 2, refreshed: 1 }, Migration::Copy.run!(@connection))
    first = item_for(1)
    assert_equal ['in_progress', '2026-11-01 09:00:00'], [first['status'], first['started_at'].to_s.first(19)]
    assert_equal 'Closing up', item_for(6)['title']
    assert_equal({ assignments: 0, events: 0, refreshed: 0 }, Migration::Copy.run!(@connection))
  end

  test 'a count mismatch stops the copy and saves nothing' do
    @connection.execute(<<~SQL.squish)
      INSERT INTO tasks (tenant_id, title, status, kind, details) VALUES ('t1', 'Stray', 'assigned', 'training_assignment', '{"legacy_id":99}')
    SQL
    error = assert_raises(StandardError) { run_migration(:up) }
    assert_match(/copy check failed: 5 assignments, 5 linked, 6 copies/, error.message)
    assert_not @connection.column_exists?(:training_assignments, :work_item_id)
    assert_equal 1, value("SELECT COUNT(*) FROM tasks WHERE kind = 'training_assignment'")
    assert_equal 0, value('SELECT COUNT(*) FROM work_item_events')
  end

  test 'down removes the copies and the added columns, and up runs again' do
    run_migration(:up)
    run_migration(:down)
    assert_equal @before, snapshot
    assert_equal 0, value("SELECT COUNT(*) FROM tasks WHERE kind = 'training_assignment'")
    assert_equal 3, value("SELECT COUNT(*) FROM tasks WHERE kind = 'task'")
    assert_equal 0, value('SELECT COUNT(*) FROM work_item_events')
    assert_not @connection.column_exists?(:training_assignments, :work_item_id)
    assert_not @connection.column_exists?(:work_item_events, :details)
    assert_empty @connection.execute('PRAGMA foreign_key_check')
    assert_equal 1, @connection.select_value('PRAGMA foreign_keys')

    run_migration(:up)
    assert_equal 5, value("SELECT COUNT(*) FROM tasks WHERE kind = 'training_assignment'")
    assert_equal @before, snapshot
  end

  test 'down is refused while training items exist that have no old row' do
    run_migration(:up)
    @connection.execute("INSERT INTO tasks (tenant_id, title, status, kind, details) VALUES ('t1', 'New', 'assigned', 'training_assignment', '{}')")
    error = assert_raises(StandardError) { run_migration(:down) }
    assert_match(/made after this migration/, error.message)
    assert @connection.column_exists?(:training_assignments, :work_item_id)
    assert_equal 6, value("SELECT COUNT(*) FROM tasks WHERE kind = 'training_assignment'")
  end

  private

  def value(sql) = @connection.select_value(sql).to_i

  def item_for(legacy_id)
    id = @connection.select_value("SELECT work_item_id FROM training_assignments WHERE id = #{legacy_id}")
    @connection.select_one("SELECT * FROM tasks WHERE id = #{id}")
  end

  def build_tables
    @connection.create_table(:tasks) do |t|
      t.string :tenant_id, null: false
      t.string :title, null: false
      t.text :description
      t.string :status, null: false, default: 'todo'
      t.string :priority, default: 'medium'
      t.string :assignee_id
      t.date :due_on
      t.datetime :completed_at
      t.string :kind, null: false, default: 'task'
      t.string :requester_id
      t.datetime :started_at
      t.bigint :parent_id
      t.string :source_type
      t.bigint :source_id
      t.text :details
      t.timestamps null: true
    end
    @connection.create_table(:work_item_events) do |t|
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
    @connection.create_table(:training_modules) do |t|
      t.string :tenant_id, null: false
      t.string :title, null: false
      t.integer :revision, null: false, default: 1
      t.timestamps null: true
    end
    @connection.create_table(:training_assignments) do |t|
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
    @connection.create_table(:training_assignment_events) do |t|
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
    @connection.execute("INSERT INTO tasks (id, tenant_id, title, status) VALUES (1, 't1', 'Order stock', 'done'), (2, 't1', 'Shelve', 'todo'), (3, 't2', 'Theirs', 'todo')")
    @connection.execute(<<~SQL.squish)
      INSERT INTO training_modules (id, tenant_id, title, revision) VALUES (1, 't1', 'Opening the store', 3), (2, 't1', 'Closing up', 1),
        (3, 't2', 'Their module', 1)
    SQL
    @connection.execute(<<~SQL.squish)
      INSERT INTO training_assignments (id, tenant_id, training_module_id, assignee_id, assigned_by_id, due_on, status, started_at, completed_at,
        completed_by_id, completed_revision, cancelled_at, created_at, updated_at) VALUES
        (1, 't1', 1, 8, 9, NULL, 'assigned', NULL, NULL, NULL, NULL, NULL, '2026-10-01 08:00:00', '2026-10-01 08:00:00'),
        (2, 't1', 2, 7, 9, '2026-10-30', 'in_progress', '2026-10-02 09:00:00', NULL, NULL, NULL, NULL, '2026-10-01 08:00:00', '2026-10-02 09:00:00'),
        (3, 't1', 1, 7, 9, '2026-10-20', 'completed', '2026-10-02 09:00:00', '2026-10-03 10:00:00', 7, 2, NULL, '2026-10-01 08:00:00', '2026-10-03 10:00:00'),
        (4, 't1', 2, 8, 9, NULL, 'cancelled', NULL, NULL, NULL, NULL, '2026-10-04 11:00:00', '2026-10-01 08:00:00', '2026-10-04 11:00:00'),
        (5, 't2', 3, 30, NULL, NULL, 'assigned', NULL, NULL, NULL, NULL, NULL, '2026-10-01 08:00:00', '2026-10-01 08:00:00')
    SQL
    @connection.execute(<<~SQL.squish)
      INSERT INTO training_assignment_events (id, tenant_id, training_assignment_id, actor_id, actor_name, action, from_status, to_status,
        module_revision, note, created_at) VALUES
        (1, 't1', 1, 9, 'Mona Manager', 'assigned', NULL, 'assigned', 1, NULL, '2026-10-01 08:00:00'),
        (2, 't1', 2, 9, 'Mona Manager', 'assigned', NULL, 'assigned', 1, NULL, '2026-10-01 08:00:00'),
        (3, 't1', 2, 7, 'Sam Staff', 'started', 'assigned', 'in_progress', 1, NULL, '2026-10-02 09:00:00'),
        (4, 't1', 3, 9, 'Mona Manager', 'assigned', NULL, 'assigned', 1, NULL, '2026-10-01 08:00:00'),
        (5, 't1', 3, 7, 'Sam Staff', 'started', 'assigned', 'in_progress', 1, NULL, '2026-10-02 09:00:00'),
        (6, 't1', 3, 7, 'Sam Staff', 'completed', 'in_progress', 'completed', 2, NULL, '2026-10-03 10:00:00'),
        (7, 't1', 4, 9, 'Mona Manager', 'assigned', NULL, 'assigned', 1, NULL, '2026-10-01 08:00:00'),
        (8, 't1', 4, 9, 'Mona Manager', 'cancelled', 'assigned', 'cancelled', 1, 'Wrong person', '2026-10-04 11:00:00'),
        (9, 't2', 5, NULL, 'system', 'assigned', NULL, 'assigned', 1, NULL, '2026-10-01 08:00:00')
    SQL
  end

  def run_migration(direction)
    migration = Migration.new('MoveTrainingAssignmentsToWorkItems', VERSION)
    migration.suppress_messages do
      ActiveRecord::Migrator.new(direction, [migration], @pool.schema_migration, @pool.internal_metadata, VERSION).run
    end
  end

  # The old tables row for row, without the mapping column the migration adds.
  def snapshot
    OLD_TABLES.to_h { |table| [table, @connection.select_all("SELECT * FROM #{table} ORDER BY id").to_a.map { |row| row.except('work_item_id') }] }
  end
end
