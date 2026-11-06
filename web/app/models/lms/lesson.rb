# frozen_string_literal: true

# One lesson: a few minutes of reading (Lms::Markup body), an optional diagram, and a short quiz.
class Lms::Lesson < ApplicationRecord
  include TenantScoped

  BODY_LIMIT = 40_000

  belongs_to :course, class_name: 'Lms::Course', inverse_of: :lessons
  has_many :questions, -> { order(:position, :id) }, class_name: 'Lms::Question', inverse_of: :lesson, dependent: :destroy
  has_many :progresses, class_name: 'Lms::LessonProgress', inverse_of: :lesson, dependent: :destroy

  accepts_nested_attributes_for :questions, allow_destroy: true, reject_if: ->(attrs) { attrs['prompt'].to_s.strip.empty? && attrs['id'].blank? }

  normalizes :title, :summary, with: ->(value) { value.to_s.squish.presence }
  normalizes :slug, with: ->(value) { value.to_s.strip.downcase }
  normalizes :diagram, with: ->(value) { value.to_s.strip.presence }

  validates :tenant_id, :title, presence: true
  validates :title, length: { maximum: 160 }
  validates :summary, length: { maximum: 300 }
  validates :slug, presence: true, format: { with: Lms::Course::SLUG_FORMAT }, length: { maximum: 80 }, uniqueness: { scope: :course_id }
  validates :minutes, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 60 }
  validates :body, length: { maximum: BODY_LIMIT }
  validate :diagram_exists
  validate :same_tenant_as_course

  def to_param = slug
  def number = (course.lessons.to_a.index(self) || 0) + 1
  def name = title

  private

  def diagram_exists
    return if diagram.blank? || Lms::Markup::DIAGRAMS.include?(diagram)

    errors.add(:diagram, "is not one of: #{Lms::Markup::DIAGRAMS.join(', ')}")
  end

  def same_tenant_as_course
    errors.add(:course, 'must belong to this workspace') if course && course.tenant_id != tenant_id
  end
end
