# frozen_string_literal: true

# Puts people on courses. Idempotent: an existing enrollment is never duplicated, and a rule or a
# manager can only make an enrollment stricter (required, earlier due date), never looser.
module Lms::Enroller
  module_function

  # Applies every rule of every published course to one person. Called when they open the
  # Learning center, so a new account is covered without a background job.
  def ensure_for(user)
    return [] unless user&.active?

    created = []
    Lms::AssignmentRule.where(tenant_id: user.tenant_id).includes(:course).find_each do |rule|
      next unless rule.course.published? && rule.matches?(user)

      enrollment = enroll!(rule.course, user, source: 'rule', rule: rule, required: rule.required?, due_on: rule.due_on_from)
      created << enrollment if enrollment.previously_new_record?
    end
    created
  end

  # A person starting a published course on their own.
  def self_enroll!(course, user)
    enroll!(course, user, source: 'self')
  end

  # A manager assigning by hand. Returns [created, already_enrolled].
  def assign!(course, users, actor:, required: false, due_on: nil)
    created = []
    existing = []
    Array(users).uniq.each do |user|
      enrollment = enroll!(course, user, source: 'manual', required: required, due_on: due_on, actor: actor)
      (enrollment.previously_new_record? ? created : existing) << enrollment
    end
    [created, existing]
  end

  # Applies a new or changed rule to everyone it reaches right now.
  def apply_rule!(rule)
    return [] unless rule.course.published?

    Lms::Audience.users_for(rule).filter_map do |user|
      enrollment = enroll!(rule.course, user, source: 'rule', rule: rule, required: rule.required?, due_on: rule.due_on_from)
      enrollment if enrollment.previously_new_record?
    end
  end

  def enroll!(course, user, source:, rule: nil, required: false, due_on: nil, actor: nil)
    raise ArgumentError, 'course and user must share a workspace' unless course.tenant_id == user.tenant_id

    Lms::Enrollment.transaction do
      enrollment = Lms::Enrollment.tenant_unscoped(course.tenant_id).find_or_initialize_by(course_id: course.id, user_id: user.id)
      if enrollment.new_record?
        enrollment.assign_attributes(tenant_id: course.tenant_id, source: source, assignment_rule: rule, required: required,
          due_on: due_on, assigned_by: actor)
      else
        enrollment.required = true if required && !enrollment.required?
        enrollment.due_on = due_on if due_on && (enrollment.due_on.nil? || due_on < enrollment.due_on)
        enrollment.assignment_rule ||= rule
        enrollment.assigned_by ||= actor
      end
      enrollment.save!
      enrollment
    end
  rescue ActiveRecord::RecordNotUnique
    Lms::Enrollment.tenant_unscoped(course.tenant_id).find_by!(course_id: course.id, user_id: user.id)
  end
  module_function :enroll!
end
