# frozen_string_literal: true

# Records what a person did on a course and rolls it up: viewing a lesson starts the course,
# passing every lesson's quiz completes it and awards the badge. Writes are per enrollment and
# locked, so two tabs cannot double-count.
class Lms::Progress
  attr_reader :enrollment

  def initialize(enrollment)
    @enrollment = enrollment
  end

  def viewed!(lesson)
    enrollment.with_lock do
      progress = find_or_build(lesson)
      progress.viewed_at ||= Time.current
      progress.save!
      enrollment.current_lesson = lesson
      if enrollment.status == 'assigned'
        enrollment.status = 'in_progress'
        enrollment.started_at ||= Time.current
      end
      enrollment.save!
      progress
    end
  end

  # Grades, records the attempt and, on a pass, marks the lesson (and maybe the course) done.
  def answer!(lesson, raw_answers)
    result = Lms::QuizGrader.grade(lesson, raw_answers)
    enrollment.with_lock do
      progress = find_or_build(lesson)
      progress.viewed_at ||= Time.current
      progress.attempts += 1
      progress.best_score = [progress.best_score, result.score].max
      progress.passed_at ||= Time.current if result.passed?
      progress.save!
      Lms::QuizAttempt.create!(tenant_id: enrollment.tenant_id, lesson_progress: progress, user_id: enrollment.user_id,
        answers_json: JSON.generate(result.answers), correct_count: result.correct_count, total_count: result.total_count,
        passed: result.passed?)
      enrollment.current_lesson = lesson
      enrollment.status = 'in_progress' if enrollment.status == 'assigned'
      enrollment.started_at ||= Time.current
      complete_if_done!
      enrollment.save!
    end
    result
  end

  private

  def find_or_build(lesson)
    enrollment.lesson_progresses.reload.find { |progress| progress.lesson_id == lesson.id } ||
      enrollment.lesson_progresses.build(tenant_id: enrollment.tenant_id, lesson: lesson, user_id: enrollment.user_id)
  end

  def complete_if_done!
    return if enrollment.completed?

    lessons = enrollment.course.lessons.reload.to_a
    return if lessons.empty?

    passed_ids = enrollment.lesson_progresses.reload.select(&:passed?).map(&:lesson_id)
    return unless lessons.all? { |lesson| passed_ids.include?(lesson.id) }

    enrollment.status = 'completed'
    enrollment.completed_at = Time.current
    enrollment.badge_awarded_at ||= enrollment.completed_at
    ActivityLogger.log('lms_course_completed', subject: enrollment.course, details: enrollment.course.title, actor: enrollment.user)
  end
end
