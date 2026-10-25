# frozen_string_literal: true

module Mcp
  module Tools
    class StaffSchedule < Tool
      MAX_DAYS = 31
      STAFF_STATUSES = %w[active on_leave].freeze

      tool 'staff_schedule',
        title: 'Staff schedule',
        description: 'Who is scheduled to work, from the Team schedule (planned shifts, not hours worked). view=schedule ' \
                     '(default) gives each day in the range with every scheduled person, start and end time, shift role and ' \
                     'hours, days with nobody scheduled, approved leave, and total scheduled hours per person. Answers "who is ' \
                     'working Saturday" or "is anyone on tomorrow morning". view=staff lists current staff (name, position, ' \
                     'department, employment type, status) with their scheduled hours in the range. Default range today to ' \
                     '6 days ahead, max 31 days. Filter by employee name. No contact details, pay or leave balances. If the ' \
                     'token owner cannot open the Team schedule page, only their own shifts are returned. For hours actually ' \
                     'worked use time_keeping_report. Read-only.',
        scope: 'timesheets:read'

      input_schema(
        type: 'object',
        properties: {
          from: DATE_PROPERTY.merge(description: 'First day (inclusive). Default today.'),
          to: DATE_PROPERTY.merge(description: 'Last day (inclusive). Default 6 days after from.'),
          view: { type: 'string', enum: %w[schedule staff], description: 'Default schedule.' },
          employee: { type: 'string', maxLength: 80, description: 'Part of a staff member\'s first or last name.' },
          **PAGE_PROPERTIES
        },
        additionalProperties: false
      )

      def call(args)
        from = date_arg(args, 'from', Date.current)
        from, to = date_range(args, default_from: from, default_to: from + 6, max_days: MAX_DAYS)
        employees = visible_employees(args['employee'])
        shifts = People::ScheduledShift.includes(:employee)
          .where(employee_id: employees.select(:id))
          .where(starts_at: from.in_time_zone.beginning_of_day...(to + 1).in_time_zone.beginning_of_day)
          .chronological.to_a
        args['view'] == 'staff' ? staff_view(args, from, to, employees, shifts) : schedule_view(args, from, to, employees, shifts)
      end

      private

      # Same rule as the Team schedule page (hr.read, schedule.write or hr.write):
      # those people see everyone; anyone else only their own shifts.
      def all_employees?
        return @all_employees if defined?(@all_employees)

        @all_employees = ModulePolicy.new(user, :module).schedule_read?
      end

      def scope_label = all_employees? ? 'all staff' : 'own shifts only'

      def visible_employees(name)
        scope = People::Employee.all
        unless all_employees?
          worker = TimeClockService.worker_for(user, include_on_leave: true)
          scope = worker ? scope.where(id: worker.id) : scope.none
        end
        return scope if name.blank?

        like = "%#{People::Employee.sanitize_sql_like(name.strip.downcase)}%"
        scope.where("LOWER(employees.first_name || ' ' || employees.last_name) LIKE :q OR LOWER(COALESCE(employees.legal_name, '')) LIKE :q", q: like)
      end

      def schedule_view(args, from, to, employees, shifts)
        by_day = shifts.group_by { |shift| shift.starts_at.in_time_zone.to_date }
        leave = approved_leave(employees, from, to)
        days = (from..to).map do |date|
          day_shifts = Array(by_day[date])
          { date: date.iso8601, weekday: date.strftime('%A'), people_scheduled: day_shifts.map(&:employee_id).uniq.size,
            scheduled_hours: day_shifts.sum(&:hours).round(2), shifts: day_shifts.map { |shift| shift_row(shift) },
            on_leave: leave.select { |request| request.starts_on <= date && request.ends_on >= date }.map { |request| request.employee.name }.uniq }
        end
        rows, meta = paginate(days, args, default_per_page: MAX_DAYS)
        people = person_totals(shifts)
        data = { from: from.iso8601, to: to.iso8601, view: 'schedule', scope: scope_label,
                 totals: { shifts: shifts.size, people: people.size, scheduled_hours: shifts.sum(&:hours).round(2) },
                 people: people, days: rows, meta: meta }
        data[:leave_note] = 'Approved leave is not shown: the token owner has no leave.read permission.' unless leave_visible?
        result(schedule_text(data, rows), data)
      end

      def staff_view(args, from, to, employees, shifts)
        hours = shifts.group_by(&:employee_id).transform_values { |list| list.sum(&:hours).round(2) }
        staff = employees.where(status: STAFF_STATUSES).includes(:position, :department).ordered
        rows, meta = paginate(staff, args)
        data = { from: from.iso8601, to: to.iso8601, view: 'staff', scope: scope_label,
                 total_staff: staff.count, rows: rows.map { |person| staff_row(person, hours) }, meta: meta }
        text = if rows.empty?
          "No current staff match (#{scope_label})."
        else
          "#{data[:total_staff]} current staff (#{scope_label})#{' (more available)' if meta[:has_more]}: " +
            data[:rows].first(15).map { |row| "#{row[:name]}#{" (#{row[:position]})" if row[:position]}#{' on leave' if row[:status] == 'on_leave'}" }.join(', ') + '.'
        end
        result(text.first(600), data)
      end

      def leave_visible?
        user.can?('leave.read') || !all_employees?
      end

      def approved_leave(employees, from, to)
        return [] unless leave_visible?

        People::LeaveRequest.includes(:employee).where(status: 'approved', employee_id: employees.select(:id))
          .where('starts_on <= ? AND ends_on >= ?', to, from).to_a
      end

      def shift_row(shift)
        { employee_id: shift.employee_id, employee: shift.employee.name, starts_at: iso(shift.starts_at), ends_at: iso(shift.ends_at),
          time: shift.time_label, hours: shift.hours.round(2), role: shift.role_label.presence }
      end

      def person_totals(shifts)
        shifts.group_by(&:employee).map do |employee, list|
          { employee_id: employee.id, employee: employee.name, shifts: list.size, scheduled_hours: list.sum(&:hours).round(2),
            days: list.map { |shift| shift.starts_at.to_date.iso8601 }.uniq }
        end.sort_by { |row| [-row[:scheduled_hours], row[:employee]] }
      end

      def staff_row(person, hours)
        { employee_id: person.id, name: person.name, position: person.position&.name, department: person.department&.name,
          employment_type: person.employment_type, status: person.status, scheduled_hours_in_range: hours.fetch(person.id, 0) }
      end

      def schedule_text(data, days)
        totals = data[:totals]
        head = "#{data[:from]} to #{data[:to]} (#{data[:scope]}): #{totals[:shifts]} shifts, #{totals[:people]} people, " \
               "#{totals[:scheduled_hours]} h scheduled."
        parts = days.map do |day|
          label = "#{day[:weekday][0, 3]} #{day[:date][5..]}"
          who = day[:shifts].empty? ? 'nobody scheduled' : day[:shifts].map { |shift| "#{shift[:employee]} #{shift[:time]}" }.join(', ')
          who += "; on leave: #{day[:on_leave].join(', ')}" if day[:on_leave].any?
          "#{label}: #{who}"
        end
        text = head
        parts.each do |part|
          break text += ' …' if text.size + part.size > 580

          text += " #{part}."
        end
        text
      end
    end
  end
end
