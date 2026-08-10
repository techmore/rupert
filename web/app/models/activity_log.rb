# frozen_string_literal: true

# An entry in the audit trail: who did what, to which subject, when.
class ActivityLog < ApplicationRecord
  include TenantScoped

  belongs_to :user, optional: true

  validates :action, presence: true

  scope :recent, ->(limit = 200) { order(created_at: :desc).limit(limit) }
  scope :for_subject, ->(type, id) { where(subject_type: type, subject_id: id.to_s) }

  def subject
    return if subject_type.blank? || subject_id.blank?

    subject_type.constantize.find_by(id: subject_id)
  rescue StandardError
    nil
  end
end
