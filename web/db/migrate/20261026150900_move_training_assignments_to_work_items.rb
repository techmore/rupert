# frozen_string_literal: true

# Shared work items, phase 2b (#407 #409): training assignments become kind 'training_assignment' rows of the shared
# work-item table (`tasks`), and their history moves into `work_item_events`.
#
# Additive only. Auto-deploy runs db:migrate before the restart and does not revert migrations when it rolls code
# back, so the previous release must keep working on the migrated database:
# - `training_assignments` and `training_assignment_events` are kept as they are (no row is changed or removed).
#   They become read-only for this release; drop them only in a later, separate pull request.
# - each old row gets `work_item_id`, the id of its copy, so old /employee/training/:id links redirect.
# - `work_item_events.details` (new, JSON) holds facts a kind keeps on each history row (training: module revision).
#
# Copy (idempotent; `Copy.run!` is also the `training:copy_legacy_assignments` task for a re-run after a rollback):
#   assignment → tasks: kind 'training_assignment', title = module title, source = the TrainingModule, assignee,
#     requester = assigned_by, due_on, status, started_at, completed_at (the cancel time for cancelled rows),
#     details = { legacy_id, completed_revision, completed_by_id }, created_at/updated_at.
#   event → work_item_events: assigned → created; started/completed/cancelled → transitioned (start/complete/cancel),
#     with from/to status, actor, actor name, note and time; details = { module_revision, legacy_event_id }.
# Then it counts: every old assignment must have exactly one copy and every old event one copied event, or the
# migration stops and nothing is saved.
#
# Rollback: `bin/rails db:migrate:down VERSION=20261026150900` outside any open transaction (back up first). It is
# refused while training items exist that were created after this migration (they have no old row and would be
# lost). It removes the copies and their history, and the two added columns; the old tables are untouched.
# See docs/architecture/shared-work-items.md.
class MoveTrainingAssignmentsToWorkItems < ActiveRecord::Migration[8.1]
  # SQLite rebuilds a table to remove a column; training_assignment_events points at training_assignments, so the
  # rollback turns foreign-key checks off first, which must happen outside a transaction.
  disable_ddl_transaction!

  KIND = 'training_assignment'

  def up
    connection.transaction do
      add_column :work_item_events, :details, :text
      add_column :training_assignments, :work_item_id, :bigint
      add_index :training_assignments, :work_item_id, name: 'idx_training_assignments_work_item'
      Copy.run!(connection)
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Run this SQLite rollback outside an existing transaction.' if connection.transaction_open?

    unmatched = connection.select_value(<<~SQL.squish).to_i
      SELECT COUNT(*) FROM tasks WHERE kind = '#{KIND}'
        AND id NOT IN (SELECT work_item_id FROM training_assignments WHERE work_item_id IS NOT NULL)
    SQL
    if unmatched.positive?
      raise ActiveRecord::IrreversibleMigration,
        "#{unmatched} training assignment(s) were made after this migration and exist only in the shared table; rolling back would lose them."
    end

    connection.disable_referential_integrity do
      connection.transaction do
        safety_assured do
          execute("DELETE FROM work_item_events WHERE item_kind = '#{KIND}'")
          execute("DELETE FROM tasks WHERE kind = '#{KIND}'")
          remove_index :training_assignments, name: 'idx_training_assignments_work_item'
          remove_column :training_assignments, :work_item_id
          remove_column :work_item_events, :details
        end
      end
    end
  end

  # Copies old assignments and events that have no copy yet, brings copies up to date with rows the previous release
  # changed after the copy, and checks the counts. Plain SQL on the given connection, so it does not depend on the
  # application models (and runs on the migration test's own database).
  class Copy
    ACTIONS = { 'assigned' => ['created', nil], 'started' => %w[transitioned start], 'completed' => %w[transitioned complete],
                'cancelled' => %w[transitioned cancel] }.freeze

    class CountMismatch < StandardError; end

    def self.run!(connection) = new(connection).run!

    def initialize(connection)
      @connection = connection
    end

    # Returns { assignments:, events:, refreshed: } (rows copied or brought up to date this run).
    def run!
      result = { assignments: 0, events: 0, refreshed: 0 }
      @connection.transaction do
        result[:assignments] = copy_assignments
        result[:refreshed] = refresh_changed
        result[:events] = copy_events
        verify!
      end
      result
    end

    def verify!
      legacy = count('SELECT COUNT(*) FROM training_assignments')
      linked = count(<<~SQL.squish)
        SELECT COUNT(*) FROM training_assignments a JOIN tasks t ON t.id = a.work_item_id
          AND t.kind = '#{KIND}' AND t.tenant_id = a.tenant_id AND t.source_type = 'TrainingModule' AND t.source_id = a.training_module_id
      SQL
      copies = count("SELECT COUNT(*) FROM tasks WHERE kind = '#{KIND}' AND details LIKE '%\"legacy_id\":%'")
      legacy_events = count('SELECT COUNT(*) FROM training_assignment_events')
      copied_events = count("SELECT COUNT(*) FROM work_item_events WHERE item_kind = '#{KIND}' AND details LIKE '%\"legacy_event_id\":%'")
      return if legacy == linked && legacy == copies && legacy_events == copied_events

      raise CountMismatch, "Training copy check failed: #{legacy} assignments, #{linked} linked, #{copies} copies; " \
                           "#{legacy_events} events, #{copied_events} copied events. Nothing was saved."
    end

    private

    def count(sql) = @connection.select_value(sql).to_i

    def copy_assignments
      titles = @connection.select_rows('SELECT id, title FROM training_modules').to_h { |id, title| [id.to_i, title] }
      rows = @connection.select_all('SELECT * FROM training_assignments WHERE work_item_id IS NULL ORDER BY id').to_a
      rows.each do |row|
        item_id = insert('tasks', item_columns(row, titles).merge('created_at' => row['created_at']))
        @connection.update("UPDATE training_assignments SET work_item_id = #{Integer(item_id)} WHERE id = #{Integer(row['id'])}")
      end
      rows.size
    end

    # The previous release (after a code rollback) may have started, completed or cancelled an assignment that was
    # already copied; its old row is then newer than the copy.
    def refresh_changed
      rows = @connection.select_all(<<~SQL.squish).to_a
        SELECT a.*, t.details AS item_details FROM training_assignments a JOIN tasks t ON t.id = a.work_item_id
          WHERE t.kind = '#{KIND}' AND a.updated_at > t.updated_at
      SQL
      rows.each do |row|
        columns = item_columns(row, nil).slice('status', 'due_on', 'started_at', 'completed_at', 'updated_at')
        details = parse(row['item_details']).merge(item_details(row))
        assignments = columns.merge('details' => details.to_json).map { |name, value| "#{@connection.quote_column_name(name)} = #{@connection.quote(value)}" }
        @connection.update("UPDATE tasks SET #{assignments.join(', ')} WHERE id = #{Integer(row['work_item_id'])}")
      end
      rows.size
    end

    def copy_events
      done = @connection.select_values("SELECT details FROM work_item_events WHERE item_kind = '#{KIND}' AND details LIKE '%\"legacy_event_id\":%'")
        .filter_map { |text| parse(text)['legacy_event_id'] }.to_set
      events = @connection.select_all(<<~SQL.squish).to_a
        SELECT e.*, a.work_item_id FROM training_assignment_events e JOIN training_assignments a ON a.id = e.training_assignment_id
          ORDER BY e.created_at, e.id
      SQL
      missing = events.reject { |event| done.include?(event['id'].to_i) }
      missing.each do |event|
        action, transition = ACTIONS.fetch(event['action'])
        insert('work_item_events', {
          'tenant_id' => event['tenant_id'], 'work_item_id' => event['work_item_id'], 'item_kind' => KIND, 'action' => action,
          'transition' => transition, 'from_status' => event['from_status'], 'to_status' => event['to_status'],
          'actor_id' => event['actor_id'], 'actor_name' => event['actor_name'], 'field_changes' => '{}', 'note' => event['note'],
          'details' => { 'module_revision' => event['module_revision'].to_i, 'legacy_event_id' => event['id'].to_i }.to_json,
          'created_at' => event['created_at']
        })
      end
      missing.size
    end

    def item_columns(row, titles)
      columns = {
        'tenant_id' => row['tenant_id'], 'kind' => KIND, 'status' => row['status'], 'assignee_id' => row['assignee_id'].to_s,
        'requester_id' => row['assigned_by_id']&.to_s, 'due_on' => row['due_on'], 'started_at' => row['started_at'],
        'completed_at' => row['status'] == 'cancelled' ? row['cancelled_at'] : row['completed_at'],
        'source_type' => 'TrainingModule', 'source_id' => row['training_module_id'], 'details' => item_details(row).to_json,
        'updated_at' => row['updated_at']
      }
      columns['title'] = titles.fetch(row['training_module_id'].to_i, 'Training').to_s.first(200).presence || 'Training' if titles
      columns
    end

    def item_details(row)
      { 'legacy_id' => row['id'].to_i, 'completed_revision' => row['completed_revision']&.to_i, 'completed_by_id' => row['completed_by_id']&.to_i }.compact
    end

    def parse(text)
      value = JSON.parse(text.to_s.presence || '{}')
      value.is_a?(Hash) ? value : {}
    rescue JSON::ParserError
      {}
    end

    def insert(table, values)
      names = values.keys.map { |name| @connection.quote_column_name(name) }.join(', ')
      quoted = values.values.map { |value| @connection.quote(value) }.join(', ')
      @connection.insert("INSERT INTO #{@connection.quote_table_name(table)} (#{names}) VALUES (#{quoted})")
    end
  end
end
