# frozen_string_literal: true

# One graded quiz submission. Append-only: it is the evidence behind a completion.
class Lms::QuizAttempt < ApplicationRecord
  include TenantScoped

  belongs_to :lesson_progress, class_name: 'Lms::LessonProgress', inverse_of: :quiz_attempts
  belongs_to :user

  attr_readonly :tenant_id, :lesson_progress_id, :user_id, :answers_json, :correct_count, :total_count, :passed

  validates :tenant_id, :answers_json, presence: true

  before_destroy(prepend: true) { throw :abort }

  def answers
    JSON.parse(answers_json)
  rescue JSON::ParserError
    {}
  end

  def score = total_count.zero? ? 0 : (correct_count * 100.0 / total_count).round
end
