# frozen_string_literal: true

module Mcp
  module Tools
    # Adds a task to Rupert's own task list — never Shopify, Square or C-Trax.
    # Requires the tasks:write scope.
    class CreateTask < Tool
      tool 'create_task',
        title: 'Create a task (writes to Rupert)',
        description: 'WRITES DATA: adds one task to Rupert\'s own Tasks board (status todo). It never changes Shopify, Square ' \
                     'or C-Trax. The description is marked as added by an AI assistant. Confirm with the person you are ' \
                     'helping before creating tasks. Pass dry_run: true to validate and preview the task without saving it. Pass ' \
                     'idempotency_key (any unique string) so a retry within 24 hours returns the first result instead of adding a second task. ' \
                     'Limited to 20 task writes per token per minute. Returns the new task.',
        scope: 'tasks:write', read_only: false, destructive: false, idempotent: false

      include TaskWriteGuard

      input_schema(
        type: 'object',
        properties: {
          title: { type: 'string', minLength: 1, maxLength: 200, description: 'Short task title.' },
          description: { type: 'string', maxLength: 4000, description: 'Details for the person doing the task.' },
          priority: { type: 'string', enum: Projects::Task::PRIORITIES, description: 'Default medium.' },
          due_on: DATE_PROPERTY.merge(description: 'Optional due date, YYYY-MM-DD.'),
          project_id: { type: 'string', maxLength: 40, description: 'Optional project ID (from list_tasks rows).' },
          assignee: Assignee::PROPERTY,
          assign_to_me: { type: 'boolean', description: 'Assign to the token owner. Default unassigned.' },
          dry_run: { type: 'boolean', description: 'Validate and return the task that WOULD be created, without saving. Default false.' },
          idempotency_key: { type: 'string', minLength: 1, maxLength: 120,
                             description: 'Optional unique string. A repeat call with the same key from this token within 24 hours returns the original result and creates nothing.' }
        },
        required: %w[title],
        additionalProperties: false
      )

      def call(args)
        raise ToolError.new('This token\'s owner can no longer create tasks.', kind: 'denied') unless Projects::TaskPolicy.new(user, Projects::Task).create?

        key = args['idempotency_key']
        unless dry_run?(args)
          replay = idempotent_replay(key)
          return replay if replay
        end

        task, assignee = build_task(args)
        return preview(task, assignee) if dry_run?(args)

        enforce_write_cap!
        raise ToolError.new("The task was not saved: #{task.errors.full_messages.to_sentence}.", kind: 'invalid_arguments') unless task.save

        record_write!
        ActivityLogger.log('task_created', subject: task, details: "Via MCP token #{token.token_hint}; assignee: #{task.assignee_id.presence || 'unassigned'}")
        outcome = result("Created task ##{task.id} “#{task.title}” (#{task.priority}#{", due #{task.due_on.iso8601}" if task.due_on})#{", assigned to #{Assignee.label(assignee)}" if assignee}.",
          task_data(task, assignee))
        remember_idempotent(key, outcome)
        outcome
      end

      private

      def task_data(task, assignee)
        { id: task.id, title: task.title, status: task.status, priority: task.priority, due_on: task.due_on&.iso8601, project_id: task.project_id&.to_s,
          assignee: assignee&.display_name, assignee_id: task.assignee_id }
      end

      def preview(task, assignee)
        raise ToolError.new("The task would not be saved: #{task.errors.full_messages.to_sentence}.", kind: 'invalid_arguments') unless task.valid?

        result("Dry run: would create task “#{task.title}” (#{task.priority}#{", due #{task.due_on.iso8601}" if task.due_on}). Nothing was saved.",
          task_data(task, assignee).merge(id: nil, dry_run: true, would_create: true))
      end

      def build_task(args)
        project = Projects::Project.find_by(id: args['project_id']) if args['project_id'].present?
        raise ToolError.new("No project with ID #{args['project_id'].to_s.first(40)} exists in this workspace.", kind: 'not_found') if args['project_id'].present? && !project

        assignee = args['assignee'].present? ? Assignee.resolve(user, args['assignee']) : (user if args['assign_to_me'])
        assignee = nil if assignee == :nobody
        note = "Added by an AI assistant through Rupert MCP (token “#{token.name}”)."
        description = [AgentFeedback.clean(args['description'], 4000, multiline: true), note].compact.join("\n\n")
        task = (project ? project.tasks : Projects::Task).new(
          title: AgentFeedback.clean(args['title'], 200), description: description, priority: args['priority'] || 'medium',
          due_on: (date_arg(args, 'due_on', nil) if args['due_on'].present?), assignee_id: assignee&.id&.to_s
        )
        [task, assignee]
      end
    end
  end
end
