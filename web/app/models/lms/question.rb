# frozen_string_literal: true

# One multiple-choice question: a prompt, two to six choices, the index of the right one, and
# the explanation shown after an answer (right or wrong).
class Lms::Question < ApplicationRecord
  include TenantScoped

  MAX_CHOICES = 6

  belongs_to :lesson, class_name: 'Lms::Lesson', inverse_of: :questions

  normalizes :prompt, :explanation, with: ->(value) { value.to_s.strip.presence }

  validates :tenant_id, :prompt, presence: true
  validates :prompt, length: { maximum: 500 }
  validates :explanation, length: { maximum: 1000 }
  validate :choices_are_sound

  def choices
    parsed = JSON.parse(choices_json.to_s)
    parsed.is_a?(Array) ? parsed.map(&:to_s) : []
  rescue JSON::ParserError
    []
  end

  def choices=(list)
    self.choices_json = JSON.generate(Array(list).map { |choice| choice.to_s.strip }.reject(&:empty?))
  end

  # Form input: one choice per line.
  def choices_text = choices.join("\n")

  def choices_text=(text)
    self.choices = text.to_s.split(/\r?\n/)
  end

  def correct?(index) = index.to_s == answer_index.to_s

  private

  def choices_are_sound
    list = choices
    errors.add(:choices, 'needs at least two choices') if list.size < 2
    errors.add(:choices, "has more than #{MAX_CHOICES} choices") if list.size > MAX_CHOICES
    errors.add(:choices, 'repeats a choice') if list.uniq.size != list.size
    errors.add(:answer_index, 'must point at one of the choices') unless answer_index.to_i.between?(0, [list.size - 1, 0].max)
  end
end
