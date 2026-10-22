# frozen_string_literal: true

module Mcp
  module Tools
    # "Who changed X?", "what did Sean do today?", "who approved the books?"
    # The audit trail (the in-app Activity page) filtered by person, action,
    # record and dates. Contact details, IP addresses and browser strings are
    # removed from every field before the model sees them.
    class ActivityLog < Tool
      # Calls the assistants make on someone's behalf. Hidden unless asked for,
      # so "what did Sean do" shows Sean's own work, not his questions to the bot.
      BOT_ACTIONS = %w[mcp_tool_call team_chat_tool ask_rupert_tool team_chat_slow_answer team_chat_action].freeze
      GROUPS = %w[money operator].freeze
      EMAIL = /[\w.+%-]+@[\w-]+(?:\.[\w-]+)+/
      IPV4 = /\b(?:\d{1,3}\.){3}\d{1,3}\b/
      IPV6 = /(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}/i
      PHONE = /(?<![\w-])(?:\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}(?![\w-])/
      USER_AGENT = %r{\b(?:Mozilla|AppleWebKit|curl|Wget|python-requests|okhttp|Dalvik|PostmanRuntime)/\S.*?(?=\s*(?:[|;\n]|\z))}i
      LABELLED = /\b(ip(?:[ _]?address)?|remote[ _]ip|user[ _-]?agent|ua|phone|mobile|email|e-mail|address|street)(\s*[:=]\s*)("[^"]*"|'[^']*'|[^,;|\n]+)/i

      tool 'activity_log',
        title: 'Activity log (who did what)',
        description: 'The audit trail from the Activity page: who did what, to which record, and when. Answers "who changed ' \
                     'that expense", "what did Sean do today", "who approved the books / timesheets / leave", "who placed or ' \
                     'received PO 1042", "who changed settings or permissions", "did anyone export data". Filter by person ' \
                     '(name), action (a word or prefix such as po_, timesheet_, books_, expense_, period_, settings_, ' \
                     'role_permissions, data_exported, task_), record type (PurchaseOrder, JournalEntry, Task, Expense...), ' \
                     'record id, free text and dates. Newest first, paginated, with counts by action and by person. A person ' \
                     'filter also returns when that person was last active in Rupert. Not here: sign-ins (not logged), edits ' \
                     'that Rupert does not log (vendor records, stock counts), and errors (use recent_errors). Contact details, ' \
                     'IP addresses and browsers are never shown. Read-only.',
        scope: 'system:read'

      input_schema(
        type: 'object',
        properties: {
          user: { type: 'string', maxLength: 80, description: 'Part of the person\'s name, e.g. "Sean". Matches who did it.' },
          action: { type: 'string', maxLength: 80, description: 'Part of the action name, e.g. "po_received", "approved", "timesheet_", "books_".' },
          group: { type: 'string', enum: GROUPS, description: 'money = reconciliation, expenses, payments, POs, pay runs; operator = settings, access, credentials.' },
          record_type: { type: 'string', maxLength: 60, description: 'Kind of record changed, e.g. PurchaseOrder, JournalEntry, Task, Expense, Employee.' },
          record_id: { type: 'string', maxLength: 60, description: 'Exact id of the record (use with record_type).' },
          query: { type: 'string', maxLength: 100, description: 'Text to find in the action, person, record label or details, e.g. a PO or order number.' },
          from: DATE_PROPERTY.merge(description: 'First day (inclusive). Default 30 days ago.'),
          to: DATE_PROPERTY.merge(description: 'Last day (inclusive). Default today.'),
          include_assistant_calls: { type: 'boolean', description: 'Also list the tool calls Rupert\'s assistants made. Default false.' },
          **PAGE_PROPERTIES
        },
        additionalProperties: false
      )

      class << self
        # Removes contact details, IP addresses and browser strings (and anything the request log hides) from text.
        def scrub(text, max: nil)
          return if text.nil?

          out = FeedbackSanitizer.scrub_text(text.to_s.gsub(/\p{Cc}/, ' '))
          out = out.gsub(LABELLED) { "#{Regexp.last_match(1)}#{Regexp.last_match(2)}[hidden]" }
          out = out.gsub(USER_AGENT, '[browser hidden]').gsub(EMAIL, '[email hidden]').gsub(PHONE, '[phone hidden]')
          out = out.gsub(IPV4, '[ip hidden]').gsub(IPV6) { |match| match.count(':') >= 3 || match.include?('::') ? '[ip hidden]' : match }
          out = out.squish
          max ? out.first(max) : out
        end

        # A person's name for display. Rupert stores the email when a person had no name; show the name part only.
        def person(name)
          return if name.blank?
          return name.to_s.split('@').first.to_s.tr('._', '  ').titleize if name.to_s.match?(/\A\s*#{EMAIL.source}\s*\z/o)

          scrub(name, max: 80)
        end
      end

      def call(args)
        from, to = date_range(args, default_from: Date.current - 29, max_days: 400)
        scope = filtered(args, from, to)
        rows, meta = paginate(scope.order(created_at: :desc, id: :desc), args)
        total = scope.count
        by_action = scope.group(:action).order(Arel.sql('COUNT(*) DESC')).limit(15).count
        by_person = scope.group(:actor_name).order(Arel.sql('COUNT(*) DESC')).limit(10).count
          .each_with_object(Hash.new(0)) { |(name, count), memo| memo[self.class.person(name) || 'system'] += count }
        data = { from: from.iso8601, to: to.iso8601, total: total, counts_by_action: by_action, counts_by_person: by_person,
                 rows: rows.map { |row| entry(row) }, meta: meta }
        data[:people] = people(args['user']) if args['user'].present?
        data[:assistant_calls] = args['include_assistant_calls'] ? 'included' : 'hidden (set include_assistant_calls to see them)'
        result(summary(data, args), data)
      end

      private

      def filtered(args, from, to)
        scope = ::ActivityLog.where(tenant_id: tenant.id, created_at: from.in_time_zone.beginning_of_day...(to + 1).in_time_zone.beginning_of_day)
        scope = scope.where.not(action: BOT_ACTIONS) unless args['include_assistant_calls']
        if args['user'].present?
          ids = matching_users(args['user']).pluck(:id)
          scope = scope.where('actor_name LIKE ? OR user_id IN (?)', like(args['user']), ids.presence || [0])
        end
        scope = scope.where('action LIKE ?', like(args['action'])) if args['action'].present?
        if args['group'].present?
          prefixes = ActivityController::GROUPS.fetch(args['group']).last
          scope = scope.where(prefixes.map { 'action LIKE ?' }.join(' OR '), *prefixes.map { |prefix| "#{prefix}%" })
        end
        scope = scope.where('subject_type LIKE ?', like(args['record_type'].to_s.delete(' '))) if args['record_type'].present?
        scope = scope.where(subject_id: args['record_id'].to_s.strip) if args['record_id'].present?
        if args['query'].present?
          scope = scope.where('action LIKE :q OR actor_name LIKE :q OR subject_label LIKE :q OR details LIKE :q', q: like(args['query']))
        end
        scope
      end

      def like(text) = "%#{::ActivityLog.sanitize_sql_like(text.to_s.strip)}%"

      def matching_users(name) = User.where(tenant_id: tenant.id).where('name LIKE ?', like(name))

      def entry(row)
        { id: row.id, at: iso(row.created_at), who: self.class.person(row.actor_name) || 'system', user_id: row.user_id,
          action: row.action, action_label: row.action.to_s.tr('_', ' ').strip.capitalize,
          record_type: row.subject_type&.demodulize, record_id: row.subject_id,
          record: self.class.scrub(row.subject_label, max: 120), details: self.class.scrub(row.details, max: 300) }
      end

      # When each matching person was last seen in Rupert (unless they hid their presence). Sign-ins are not logged.
      def people(name)
        matching_users(name).order(:name).limit(5).map do |person|
          { name: person.display_name, active: person.active?,
            last_active_at: person.presence_hidden ? nil : iso(person.last_active_at),
            note: person.presence_hidden ? 'This person hides when they were last active.' : nil }.compact
        end
      end

      def summary(data, args)
        filters = %w[user action group record_type record_id query].filter_map { |key| "#{key} #{args[key].to_s.first(40)}" if args[key].present? }
        head = "#{data[:total]} activity entr#{data[:total] == 1 ? 'y' : 'ies'} #{data[:from]} to #{data[:to]}" \
               "#{" (#{filters.join(', ')})" if filters.any?}"
        return "#{head}." if data[:rows].empty?

        top = data[:counts_by_action].first(4).map { |action, count| "#{action} #{count}" }.join(', ')
        latest = data[:rows].first(5).map { |row| "#{row[:at]&.first(16)&.tr('T', ' ')} #{row[:who]} #{row[:action]}#{" #{row[:record]}" if row[:record]}" }
        "#{head}. Most common: #{top}. Latest: #{latest.join('; ')}".first(600)
      end
    end
  end
end
