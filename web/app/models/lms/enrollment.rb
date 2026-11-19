# frozen_string_literal: true

# One person on one course: where it came from (a rule, a manager, or themselves), whether it is
# required and by when, and how far they are. Lesson-level detail lives in Lms::LessonProgress.
#
#   assigned ──first lesson viewed──▶ in_progress ──every quiz passed──▶ completed
class Lms::Enrollment < ApplicationRecord
  include TenantScoped

  STATUSES = %w[assigned in_progress completed].freeze
  SOURCES = %w[rule manual self].freeze
  STATUS_LABELS = { 'assigned' => 'Not started', 'in_progress' => 'In progress', 'completed' => 'Completed' }.freeze

  belongs_to :course, class_name: 'Lms::Course', inverse_of: :enrollments
  belongs_to :user
  belongs_to :assignment_rule, class_name: 'Lms::AssignmentRule', optional: true, inverse_of: :enrollments
  belongs_to :assigned_by, class_name: 'User', optional: true
  belongs_to :current_lesson, class_name: 'Lms::Lesson', optional: true
  has_many :lesson_progresses, class_name: 'Lms::LessonProgress', inverse_of: :enrollment, dependent: :destroy

  validates :tenant_id, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :source, inclusion: { in: SOURCES }
  validates :user_id, uniqueness: { scope: :course_id }
  validate :same_tenant

  scope :completed, -> { where(status: 'completed') }
  scope :open_items, -> { where.not(status: 'completed') }
  scope :required, -> { where(required: true) }
  scope :overdue, -> { open_items.where(due_on: ...Date.current) }
  scope :for_user, ->(user) { where(user_id: user.id) }

  def status_label = STATUS_LABELS.fetch(status, status.humanize)
  def completed? = status == 'completed'
  def overdue? = !completed? && due_on.present? && due_on < Date.current

  def progress_for(lesson)
    lesson_progresses.find { |progress| progress.lesson_id == lesson.id }
  end

  def passed?(lesson) = progress_for(lesson)&.passed?

  # [passed, total] across the course's lessons.
  def progress
    lessons = course.lessons.to_a
    [lessons.count { |lesson| passed?(lesson) }, lessons.size]
  end

  def percent
    done, total = progress
    total.zero? ? 0 : (done * 100.0 / total).round
  end

  # The first lesson not yet passed, or nil when the course is done.
  def next_lesson
    course.lessons.find { |lesson| !passed?(lesson) }
  end

  private

  def same_tenant
    errors.add(:course, 'must belong to this workspace') if course && course.tenant_id != tenant_id
    errors.add(:user, 'must belong to this workspace') if user && user.tenant_id != tenant_id
  end
end
