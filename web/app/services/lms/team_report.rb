# frozen_string_literal: true

require 'csv'

# Team completion for people with hr.read: every active account against every published course.
# Read-only. Rows are built from enrollments; an account with no enrollment on a course shows
# "Not assigned" so the gaps are as visible as the completions.
class Lms::TeamReport
  # `rule_matches` is true when a rule reaches the person but they have not opened the course yet
  # (enrollments are written lazily on their first visit), so the matrix shows them as assigned.
  Row = Struct.new(:user, :course, :enrollment, :rule_matches, keyword_init: true) do
    def status
      return (rule_matches ? 'assigned' : 'not_assigned') unless enrollment
      return 'overdue' if enrollment.overdue?

      enrollment.status
    end

    def status_label
      Lms::Enrollment::STATUS_LABELS.merge('not_assigned' => 'Not assigned', 'overdue' => 'Overdue').fetch(status)
    end

    def percent = enrollment&.percent || 0
  end

  attr_reader :courses, :users, :filters

  def initialize(tenant_id: Current.tenant_id, course: nil, role: nil, status: nil)
    @tenant_id = tenant_id
    @courses = Lms::Course.published.ordered.includes(:lessons).to_a
    @courses = @courses.select { |candidate| candidate.slug == course } if course.present?
    @users = User.where(tenant_id: tenant_id).active.ordered.to_a
    @users = @users.select { |user| user.role.to_s == role } if role.present?
    @filters = { course: course, role: role, status: status }
    @enrollments = Lms::Enrollment.where(course_id: @courses.map(&:id), user_id: @users.map(&:id)).includes(:lesson_progresses)
      .index_by { |enrollment| [enrollment.course_id, enrollment.user_id] }
    @rules = Lms::AssignmentRule.where(course_id: @courses.map(&:id)).group_by(&:course_id)
  end

  def rows
    @rows ||= all_rows.select { |row| filters[:status].blank? || row.status == filters[:status] }
  end

  def summary
    all = all_rows
    {
      people: users.size,
      completed: all.count { |row| row.status == 'completed' },
      in_progress: all.count { |row| row.status == 'in_progress' },
      overdue: all.count { |row| row.status == 'overdue' },
      not_started: all.count { |row| %w[assigned not_assigned].include?(row.status) }
    }
  end

  def all_rows
    @all_rows ||= users.flat_map do |user|
      courses.map do |course|
        Row.new(user: user, course: course, enrollment: @enrollments[[course.id, user.id]],
          rule_matches: Array(@rules[course.id]).any? { |rule| rule.matches?(user) })
      end
    end
  end

  def to_csv
    CSV.generate do |csv|
      csv << ['Person', 'Email', 'Role', 'Course', 'Status', 'Progress %', 'Required', 'Due', 'Completed at']
      rows.each do |row|
        csv << [row.user.display_name, row.user.email, row.user.role, row.course.title, row.status_label, row.percent,
                row.enrollment&.required? ? 'yes' : 'no', row.enrollment&.due_on, row.enrollment&.completed_at]
      end
    end
  end
end
