# frozen_string_literal: true

module Mcp
  module Tools
    class ListProjects < Tool
      VIEWS = %w[projects goals templates].freeze
      PROJECT_STATUSES = %w[planned active on_hold completed archived].freeze
      GOAL_STATUSES = %w[draft active achieved abandoned].freeze
      TASK_LIMIT = 50

      tool 'list_projects',
        title: 'List projects and goals',
        description: 'Lists Rupert projects (the in-app Projects page): status (planned, active, on_hold, completed, archived), ' \
                     'owner and member names, start and due dates, task counts (open, blocked, done, overdue), progress %, ' \
                     'health and the linked goal. Give project_id to get one project with its tasks (answers "what is left on ' \
                     'project X"). view=goals lists goals (target, current value, progress %, due date, linked projects); ' \
                     'view=templates lists saved project templates. Default hides archived projects and abandoned goals. ' \
                     'No budgets, costs or time-of-day deadlines. Paginated. Read-only.',
        scope: 'tasks:read'

      input_schema(
        type: 'object',
        properties: {
          view: { type: 'string', enum: VIEWS, description: 'projects (default), goals or templates.' },
          status: { type: 'string', enum: (PROJECT_STATUSES + GOAL_STATUSES + ['all']).uniq,
                    description: 'Projects: planned, active, on_hold, completed, archived. Goals: draft, active, achieved, abandoned. ' \
                                 'all = every status. Default: everything except archived projects / abandoned goals.' },
          query: { type: 'string', maxLength: 100, description: 'Text in the name or description.' },
          project_id: { type: 'integer', minimum: 1, description: 'One project, returned with its tasks (unfinished first).' },
          **PAGE_PROPERTIES
        },
        additionalProperties: false
      )

      def call(args)
        return project_detail(args) if args['project_id']

        case args['view'] || 'projects'
        when 'goals' then goals(args)
        when 'templates' then templates(args)
        else projects(args)
        end
      end

      private

      def projects(args)
        status = args['status']
        invalid_status!(status, PROJECT_STATUSES, 'projects')
        scope = Projects::Project.includes(:goal, :project_members)
        scope = status.nil? ? scope.where.not(status: 'archived') : (status == 'all' ? scope : scope.where(status: status))
        scope = scope.search(args['query']) if args['query'].present?
        scope = scope.order(Arel.sql('CASE WHEN projects.due_on IS NULL THEN 1 ELSE 0 END'), :due_on, Arel.sql('LOWER(projects.name)'), :id)
        rows, meta = paginate(scope, args)
        stats = task_stats(rows)
        people = names_for(rows)
        counts = Projects::Project.group(:status).count
        data = { view: 'projects', status_counts: counts, rows: rows.map { |project| project_row(project, stats, people) }, meta: meta }
        text = if rows.empty?
          "No projects match. All projects by status: #{count_label(counts)}."
        else
          "#{rows.size} project#{'s' unless rows.size == 1}#{' (more available)' if meta[:has_more]}: " +
            data[:rows].first(8).map { |row| project_label(row) }.join('; ')
        end
        result(text, data)
      end

      def project_detail(args)
        project = Projects::Project.includes(:goal, :project_members).find_by(id: args['project_id'])
        raise ToolError.new("No project with id #{args['project_id']}.", kind: 'not_found') unless project

        stats = task_stats([project])
        people = names_for([project])
        tasks = project.tasks.includes(:assignee)
          .order(Arel.sql("CASE tasks.status WHEN 'done' THEN 1 ELSE 0 END")).by_priority.limit(TASK_LIMIT + 1).to_a
        row = project_row(project, stats, people).merge(description: project.description.to_s.first(500).presence)
        data = { view: 'project', project: row, tasks: tasks.first(TASK_LIMIT).map { |task| task_row(task) },
                 tasks_truncated: tasks.size > TASK_LIMIT }
        unfinished = tasks.reject { |task| task.status == 'done' }
        text = "#{project_label(row)}. " +
               (unfinished.empty? ? 'No unfinished tasks.' : "Unfinished: #{unfinished.first(8).map { |t| task_label(t) }.join('; ')}")
        result(text, data)
      end

      def goals(args)
        status = args['status']
        invalid_status!(status, GOAL_STATUSES, 'goals')
        scope = Goals::Goal.all
        scope = status.nil? ? scope.where.not(status: 'abandoned') : (status == 'all' ? scope : scope.where(status: status))
        if args['query'].present?
          like = "%#{Goals::Goal.sanitize_sql_like(args['query'].strip.downcase)}%"
          scope = scope.where("LOWER(goals.name) LIKE :q OR LOWER(COALESCE(goals.description, '')) LIKE :q", q: like)
        end
        scope = scope.order(Arel.sql('CASE WHEN goals.due_on IS NULL THEN 1 ELSE 0 END'), :due_on, :name, :id)
        rows, meta = paginate(scope, args)
        linked = Projects::Project.where(goal_id: rows.map(&:id)).where.not(status: 'archived').order(:name).group_by(&:goal_id)
        data = { view: 'goals', status_counts: Goals::Goal.group(:status).count,
                 rows: rows.map { |goal| goal_row(goal, Array(linked[goal.id])) }, meta: meta }
        text = if rows.empty?
          'No goals match.'
        else
          "#{rows.size} goal#{'s' unless rows.size == 1}#{' (more available)' if meta[:has_more]}: " +
            data[:rows].first(8).map { |row| goal_label(row) }.join('; ')
        end
        result(text, data)
      end

      def templates(args)
        scope = Projects::ProjectTemplate.alphabetical
        if args['query'].present?
          like = "%#{Projects::ProjectTemplate.sanitize_sql_like(args['query'].strip.downcase)}%"
          scope = scope.where("LOWER(project_templates.name) LIKE :q OR LOWER(COALESCE(project_templates.description, '')) LIKE :q", q: like)
        end
        rows, meta = paginate(scope, args)
        data = { view: 'templates', rows: rows.map do |template|
          { id: template.id, name: template.name, description: template.description.to_s.first(300).presence, task_count: template.task_count }
        end, meta: meta }
        text = rows.empty? ? 'No project templates.' : "#{rows.size} template#{'s' unless rows.size == 1}: " +
                                                       data[:rows].map { |row| "#{row[:name]} (#{row[:task_count]} tasks)" }.join('; ')
        result(text, data)
      end

      def invalid_status!(status, allowed, view)
        return if status.nil? || status == 'all' || allowed.include?(status)

        raise ToolError.new("status #{status} does not apply to #{view}; use one of #{(allowed + ['all']).join(', ')}.", kind: 'invalid_arguments')
      end

      # { project_id_string => { counts: {status => n}, overdue: n } } in two grouped queries.
      def task_stats(projects)
        ids = projects.map(&:id)
        grouped = Projects::Task.where(project_id: ids).group(:project_id, :status).count
        overdue = Projects::Task.overdue.where(project_id: ids).group(:project_id).count
        projects.to_h do |project|
          counts = Projects::Task::BOARD_STATUSES.index_with do |status|
            grouped.sum { |(pid, st), n| pid.to_s == project.id.to_s && st == status ? n : 0 }
          end
          [project.id.to_s, { counts: counts, overdue: overdue.sum { |pid, n| pid.to_s == project.id.to_s ? n : 0 } }]
        end
      end

      def names_for(projects)
        ids = projects.flat_map { |project| [project.owner_id, *project.project_members.map(&:user_id)] }.compact.map(&:to_s).uniq
        User.where(tenant_id: tenant.id, id: ids).to_h { |person| [person.id.to_s, person.display_name] }
      end

      def project_row(project, stats, people)
        stat = stats.fetch(project.id.to_s)
        counts = stat[:counts]
        total = counts.values.sum
        project.preload_task_stats(counts, stat[:overdue])
        {
          id: project.id, name: project.name, status: project.status, owner: people[project.owner_id.to_s],
          members: project.project_members.filter_map { |member| people[member.user_id.to_s] }.sort,
          start_on: project.start_on&.iso8601, due_on: project.due_on&.iso8601, days_left: project.days_left,
          tasks: { total: total, open: counts['todo'] + counts['in_progress'], todo: counts['todo'], in_progress: counts['in_progress'],
                   blocked: counts['blocked'], done: counts['done'], overdue: stat[:overdue] },
          progress_percent: project.progress_pct, health: project.health.to_s,
          goal: project.goal && { id: project.goal.id, name: project.goal.name, status: project.goal.status, progress_percent: project.goal.progress_pct },
          path: "/projects/#{project.id}", updated_at: iso(project.updated_at)
        }
      end

      def goal_row(goal, projects)
        { id: goal.id, name: goal.name, description: goal.description.to_s.first(300).presence, status: goal.status,
          target_value: goal.target_value&.to_f, current_value: goal.current_value&.to_f, unit: goal.unit.presence,
          progress_percent: goal.progress_pct, due_on: goal.due_on&.iso8601,
          days_left: goal.due_on && (goal.due_on - Date.current).to_i,
          projects: projects.map { |project| { id: project.id, name: project.name, status: project.status } },
          path: "/goals/goals/#{goal.id}" }
      end

      def task_row(task)
        { id: task.id, title: task.title, status: task.status, priority: task.priority, due_on: task.due_on&.iso8601,
          overdue: task.overdue?, assignee: task.assignee&.display_name, blocked_reason: task.blocked_reason }
      end

      def project_label(row)
        tasks = row[:tasks]
        parts = [row[:status], "#{tasks[:done]}/#{tasks[:total]} tasks done"]
        parts << "#{tasks[:overdue]} overdue" if tasks[:overdue].positive?
        parts << "#{tasks[:blocked]} blocked" if tasks[:blocked].positive?
        parts << "due #{row[:due_on]}" if row[:due_on]
        parts << "owner #{row[:owner]}" if row[:owner]
        parts << "goal #{row[:goal][:name]}" if row[:goal]
        "##{row[:id]} #{row[:name]} [#{parts.join(', ')}]"
      end

      def goal_label(row)
        progress = row[:target_value] ? "#{format('%g', row[:current_value].to_f)}/#{format('%g', row[:target_value])}#{" #{row[:unit]}" if row[:unit]}" : 'no target'
        progress += " (#{row[:progress_percent]}%)" if row[:progress_percent]
        "#{row[:name]} [#{row[:status]}, #{progress}#{", due #{row[:due_on]}" if row[:due_on]}#{", #{row[:projects].size} projects" if row[:projects].any?}]"
      end

      def task_label(task)
        "##{task.id} #{task.title} [#{task.status}#{", due #{task.due_on}" if task.due_on}#{", #{task.assignee.display_name}" if task.assignee}]"
      end

      def count_label(counts)
        counts.empty? ? 'none' : counts.map { |status, n| "#{n} #{status}" }.join(', ')
      end
    end
  end
end
