# frozen_string_literal: true

# One person's state on one lesson of one enrollment: when first opened, when the quiz was passed,
# how many tries, best score. Every graded try is also kept as an Lms::QuizAttempt.
class Lms::LessonProgress < ApplicationRecord
  include TenantScoped

  belongs_to :enrollment, class_name: 'Lms::Enrollment', inverse_of: :lesson_progresses
  belongs_to :lesson, class_name: 'Lms::Lesson', inverse_of: :progresses
  belongs_to :user
  has_many :quiz_attempts, -> { order(:created_at, :id) }, class_name: 'Lms::QuizAttempt', inverse_of: :lesson_progress, dependent: :destroy

  validates :tenant_id, presence: true
  validates :lesson_id, uniqueness: { scope: :enrollment_id }
  validates :attempts, :best_score, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def passed? = passed_at.present?
  def viewed? = viewed_at.present?
end
