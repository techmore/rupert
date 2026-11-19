# frozen_string_literal: true

# Grades one quiz submission. Answers are `{ "question_id" => "choice index" }` from the form.
# A lesson is passed when every question is right; wrong answers carry their explanation so the
# person can learn and try again. A lesson with no questions passes on reading.
class Lms::QuizGrader
  Result = Struct.new(:questions, :answers, :wrong, :correct_count, :total_count, keyword_init: true) do
    def passed? = wrong.empty?
    def score = total_count.zero? ? 100 : (correct_count * 100.0 / total_count).round
    def wrong?(question) = wrong.include?(question)
    def answered(question) = answers[question.id.to_s]
  end

  def self.grade(lesson, raw_answers)
    questions = lesson.questions.to_a
    answers = normalize(raw_answers, questions)
    wrong = questions.reject { |question| question.correct?(answers[question.id.to_s]) }
    Result.new(questions: questions, answers: answers, wrong: wrong, correct_count: questions.size - wrong.size, total_count: questions.size)
  end

  # Only this lesson's question ids, choice indexes as strings within range; anything else is dropped.
  def self.normalize(raw, questions)
    hash = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
    questions.each_with_object({}) do |question, out|
      value = hash[question.id.to_s].to_s
      out[question.id.to_s] = value if value.match?(/\A\d+\z/) && value.to_i < question.choices.size
    end
  end
end
