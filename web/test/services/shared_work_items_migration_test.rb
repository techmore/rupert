# frozen_string_literal: true

require 'test_helper'
require_relative '../../db/migrate/20261025190000_make_tasks_shared_work_items'

# The shared work-item migration (#407) on a copy of the task tables with rows in them: up, down and up again keep
# every task, its id and everything that points at it, and foreign keys still hold afterwards.
class SharedWorkItemsMigrationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class IsolatedDatabase < ActiveRecord::Base
    self.abstract_class = true
  end

  VERSION = 20261025190000
  TABLES = %w[projects tasks task_comments task_dependencies agent_feedbacks].freeze
  NEW_COLUMNS = %w[kind requester_id started_at parent_id source_type source_id details].freeze

  setup do
    # A separate in-memory pool: never rebuild the application test database or its fixture tables.
    IsolatedDatabase.establish_connection(adapter: 'sqlite3', database: ':memory:')
    @pool = IsolatedDatabase.connection_pool
    @connection = @pool.lease_connection
    build_task_tables
    ActiveRecord::Tasks::DatabaseTasks.stubs(:migration_connection).returns(@connection)
    ActiveRecord::Tasks::DatabaseTasks.stubs(:migration_connection_pool).returns(@pool)
    @before = snapshot
  end

  teardown do
    @pool&.disconnect!
    IsolatedDatabase.remove_connection
  end

  test 'up, down and up keep every task, id and link' do
    assert MakeTasksSharedWorkItems.disable_ddl_transaction
    assert_equal 1, @connection.select_value('PRAGMA foreign_keys')

    run_migration(:up)
    assert_equal @before, snapshot
    assert_equal %w[task task task], @connection.select_values('SELECT kind FROM tasks ORDER BY id')
    assert @connection.table_exists?(:work_item_events)
    assert @connection.index_exists?(:tasks, %i[tenant_id kind status], name: 'index_tasks_on_tenant_kind_status')

    run_migration(:down)
    assert_equal @before, snapshot
    refute @connection.table_exists?(:work_item_events)
    NEW_COLUMNS.each { |column| refute @connection.column_exists?(:tasks, column), column }
    assert_equal 1, @connection.select_value('PRAGMA foreign_keys')
    assert_empty @connection.execute('PRAGMA foreign_key_check')

    run_migration(:up)
    assert_equal @before, snapshot
    assert_empty @connection.execute('PRAGMA foreign_key_check')
    # The rebuilt table still enforces its links.
    assert_raises(ActiveRecord::InvalidForeignKey) { @connection.execute("INSERT INTO task_comments (task_id, tenant_id, body) VALUES (999, 't1', 'orphan')") }
    assert_raises(ActiveRecord::InvalidForeignKey) { @connection.execute('DELETE FROM tasks WHERE id = 10') }
  end

  test 'rollback is refused while rows of another kind exist, and inside an open transaction' do
    run_migration(:up)
    @connection.execute("INSERT INTO tasks (id, tenant_id, title, status, kind) VALUES (50, 't1', 'Training', 'assigned', 'training_assignment')")
    assert_raises(StandardError) { run_migration(:down) }
    assert @connection.table_exists?(:work_item_events)
    @connection.execute('DELETE FROM tasks WHERE id = 50')

    migration = MakeTasksSharedWorkItems.new
    @connection.transaction do
      assert_raises(ActiveRecord::IrreversibleMigration) { migration.suppress_messages { migration.exec_migration(@connection, :down) } }
    end
    assert @connection.column_exists?(:tasks, :kind)
  end

  private

  def build_task_tables
    @connection.create_table(:projects) do |t|
      t.string :tenant_id, null: false
      t.string :name
    end
    @connection.create_table(:tasks) do |t|
      t.string :tenant_id, null: false
      t.string :title, null: false
      t.string :status, null: false, default: 'todo'
      t.bigint :project_id
      t.text :labels
    end
    @connection.add_foreign_key :tasks, :projects
    @connection.create_table(:task_comments) do |t|
      t.integer :task_id, null: false
      t.string :tenant_id
      t.text :body
    end
    @connection.add_foreign_key :task_comments, :tasks
    @connection.create_table(:task_dependencies) do |t|
      t.integer :task_id, null: false
      t.integer :blocker_id, null: false
    end
    @connection.add_foreign_key :task_dependencies, :tasks
    @connection.add_foreign_key :task_dependencies, :tasks, column: :blocker_id
    @connection.create_table(:agent_feedbacks) do |t|
      t.bigint :task_id
      t.string :summary
    end
    @connection.execute("INSERT INTO projects (id, tenant_id, name) VALUES (1, 't1', 'Spring reset')")
    @connection.execute(<<~SQL.squish)
      INSERT INTO tasks (id, tenant_id, title, status, project_id, labels) VALUES
        (10, 't1', 'Order stock', 'done', 1, '["stock"]'), (11, 't1', 'Shelve stock', 'todo', 1, NULL),
        (12, 't2', 'Other workspace task', 'blocked', NULL, '[]')
    SQL
    @connection.execute("INSERT INTO task_comments (task_id, tenant_id, body) VALUES (10, 't1', 'Ordered'), (11, 't1', 'Waiting')")
    @connection.execute('INSERT INTO task_dependencies (task_id, blocker_id) VALUES (11, 10)')
    @connection.execute("INSERT INTO agent_feedbacks (task_id, summary) VALUES (11, 'Asked from chat')")
  end

  def run_migration(direction)
    migration = MakeTasksSharedWorkItems.new('MakeTasksSharedWorkItems', VERSION)
    migration.suppress_messages do
      ActiveRecord::Migrator.new(direction, [migration], @pool.schema_migration, @pool.internal_metadata, VERSION).run
    end
  end

  def snapshot
    TABLES.to_h do |table|
      [table, @connection.select_all("SELECT * FROM #{table} ORDER BY id").to_a.map { |row| row.except(*NEW_COLUMNS) }]
    end
  end
end
