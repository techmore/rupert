# frozen_string_literal: true

module Mcp
  module Tools
    # Changes one task on Rupert's own task list (never Shopify, Square or
    # C-Trax): who it is for, its column, priority, due date, title, or a note.
    # Requires the tasks:write scope and the owner's permission to edit that task.
    class UpdateTask < Tool
      tool 'update_task',
        title: 'Update a task (writes to Rupert)',
        description: 'WRITES DATA: changes one task on Rupert\'s own Tasks board: assign it (a name, an email, "me" or "nobody"), ' \
                     'move it (todo, in_progress, blocked, done), change its priority or due date, rename it, or add a note. ' \
                     'It never changes Shopify, Square or C-Trax. Find the task ID with list_tasks first. Pass dry_run: true to ' \
                     'preview the before/after of the changed fields without saving. Limited to 20 task writes per token per minute. Returns the task.',
        scope: 'tasks:write', read_only: false, destructive: true, idempotent: false

      include TaskWriteGuard

      input_schema(
        type: 'object',
        properties: {
          task_id: { type: 'integer', minimum: 1, description: 'The task ID (from list_tasks rows).' },
          assignee: Assignee::PROPERTY,
          status: { type: 'string', enum: Projects::Task::BOARD_STATUSES, description: 'Board column to move it to.' },
          priority: { type: 'string', enum: Projects::Task::PRIORITIES },
          due_on: DATE_PROPERTY.merge(description: 'New due date, YYYY-MM-DD.'),
          clear_due_date: { type: 'boolean', description: 'Remove the due date.' },
          title: { type: 'string', minLength: 1, maxLength: 200, description: 'New title.' },
          note: { type: 'string', maxLength: 1000, description: 'A note added to the end of the description.' },
          dry_run: { type: 'boolean', description: 'Validate and return a before/after of the fields that WOULD change, without saving. Default false.' }
        },
        required: %w[task_id],
        additionalProperties: false
      )

      def call(args)
        task = Projects::TaskPolicy::Scope.new(user, Projects::Task).resolve.find_by(id: args['task_id'])
        raise ToolError.new("No task ##{args['task_id']} that you can see.", kind: 'not_found') unless task
        raise ToolError.new("You cannot change task ##{task.id}.", kind: 'denied') unless Projects::TaskPolicy.new(user, task).update?

        before = snapshot(task)
        changes = apply(task, args)
        target = args['status']
        raise ToolError.new('Say what to change: assignee, status, priority, due date, title or a note.', kind: 'invalid_arguments') if changes.empty? && target.blank?

        return preview(task, before, changes, target, args) if dry_run?(args)

        enforce_write_cap!
        Projects::Task.transaction do
          raise ToolError.new("The task was not saved: #{task.errors.full_messages.to_sentence}.", kind: 'invalid_arguments') if changes.any? && !task.save

          if target.present? && target != task.status
            unless task.move_to!(target)
              waiting = %w[in_progress done].include?(target) ? task.open_blockers.limit(3).pluck(:title) : []
              raise ToolError.new("Task ##{task.id} cannot move from #{task.status} to #{target}#{"; it is waiting on #{waiting.to_sentence}" if waiting.any?}.",
                kind: 'invalid_arguments')
            end

            changes << "moved to #{target.tr('_', ' ')}"
          end
        end
        raise ToolError.new("Task ##{task.id} already looks like that.", kind: 'invalid_arguments') if changes.empty?

        record_write!
        ActivityLogger.log('task_updated', subject: task, details: "Via MCP token #{token.token_hint}; #{changes.join('; ')}".first(500))
        result("Updated task ##{task.id} “#{task.title}”: #{changes.join(', ')}.",
          { id: task.id, title: task.title, status: task.status, priority: task.priority, due_on: task.due_on&.iso8601,
            assignee: task.assignee&.display_name, assignee_id: task.assignee_id })
      end

      private

      FIELDS = %w[title status priority due_on assignee_id].freeze

      def snapshot(task)
        task.attributes.slice(*FIELDS).transform_values { |value| value.respond_to?(:iso8601) ? value.iso8601 : value }
      end

      # Nothing is saved or moved: report what the changes above would do.
      def preview(task, before, changes, target, args)
        raise ToolError.new("The change would not be saved: #{task.errors.full_messages.to_sentence}.", kind: 'invalid_arguments') unless task.valid?

        after = snapshot(task)
        if target.present? && target != task.status
          waiting = %w[in_progress done].include?(target) ? task.open_blockers.limit(3).pluck(:title) : []
          raise ToolError.new("Task ##{task.id} cannot move from #{task.status} to #{target}; it is waiting on #{waiting.to_sentence}.", kind: 'invalid_arguments') if waiting.any?

          after['status'] = target
          changes << "moved to #{target.tr('_', ' ')}"
        end
        raise ToolError.new("Task ##{task.id} already looks like that.", kind: 'invalid_arguments') if changes.empty?

        changed = after.reject { |field, value| before[field] == value }
        data = { id: task.id, dry_run: true, would_change: changed.to_h { |field, value| [field, { before: before[field], after: value }] } }
        data[:note_added] = AgentFeedback.clean(args['note'], 1000, multiline: true) if args['note'].present?
        result("Dry run: would update task ##{task.id} “#{before['title']}”: #{changes.join(', ')}. Nothing was saved.", data)
      end

      def apply(task, args)
        changes = []
        if args['assignee'].present?
          person = Assignee.resolve(user, args['assignee'])
          id = person == :nobody ? nil : person.id.to_s
          if id != task.assignee_id.presence
            task.assignee_id = id
            changes << (id ? "assigned to #{Assignee.label(person)}" : 'unassigned')
          end
        end
        if args['priority'].present? && args['priority'] != task.priority
          task.priority = args['priority']
          changes << "priority #{args['priority']}"
        end
        if args['clear_due_date'] && task.due_on
          task.due_on = nil
          changes << 'no due date'
        elsif args['due_on'].present? && (due = date_arg(args, 'due_on', nil)) != task.due_on
          task.due_on = due
          changes << "due #{due.iso8601}"
        end
        if args['title'].present? && (title = AgentFeedback.clean(args['title'], 200)) != task.title
          task.title = title
          changes << "renamed “#{title}”"
        end
        if args['note'].present?
          note = AgentFeedback.clean(args['note'], 1000, multiline: true)
          task.description = [task.description.presence, "#{note}\n— #{user.display_name}, via an AI assistant (#{Date.current.iso8601})"].compact.join("\n\n")
          changes << 'note added'
        end
        changes
      end
    end
  end
end
