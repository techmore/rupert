# frozen_string_literal: true

# "Everyone with role X (at location Y) takes this course." A rule with no role matches every
# role. Rules are applied lazily by Lms::Enroller when a person opens the Learning center and
# when a manager assigns, so a new hire gets the course without anyone remembering.
#
# Location: accounts carry no home location today (see docs/lms/OPEN-QUESTIONS.md), so a rule
# with a location matches nobody automatically; it is kept so the data model is ready.
class Lms::AssignmentRule < ApplicationRecord
  include TenantScoped

  ANY_ROLE = nil

  belongs_to :course, class_name: 'Lms::Course', inverse_of: :assignment_rules
  belongs_to :created_by, class_name: 'User', optional: true
  has_many :enrollments, class_name: 'Lms::Enrollment', inverse_of: :assignment_rule, dependent: :nullify

  normalizes :role, :location_id, with: ->(value) { value.to_s.strip.presence }

  validates :tenant_id, presence: true
  validates :role, inclusion: { in: User.roles.keys }, allow_nil: true
  validates :due_days, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 365 }, allow_nil: true

  def role_label = role ? User.new(role: role).role.humanize : 'Everyone'

  def matches?(user)
    return false unless user&.active?
    return false if role && user.role.to_s != role
    return false if location_id && !Lms::Audience.location_ids_for(user).include?(location_id)

    true
  end

  def due_on_from(date = Date.current) = due_days && date + due_days.days
end
