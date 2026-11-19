# frozen_string_literal: true

# One course: an ordered set of lessons with a quiz each, a glossary, and a badge at the end.
# Seeded courses carry `seed_key`/`seed_version`; once someone edits a seeded course
# (`edited_at`), the seeder leaves its content alone. Only published courses are shown to learners.
class Lms::Course < ApplicationRecord
  include TenantScoped

  STATUSES = %w[draft published].freeze
  SLUG_FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  has_many :lessons, -> { order(:position, :id) }, class_name: 'Lms::Lesson', inverse_of: :course, dependent: :destroy
  has_many :questions, through: :lessons
  has_many :glossary_terms, -> { order(:term) }, class_name: 'Lms::GlossaryTerm', inverse_of: :course, dependent: :destroy
  has_many :assignment_rules, -> { order(:id) }, class_name: 'Lms::AssignmentRule', inverse_of: :course, dependent: :destroy
  has_many :enrollments, class_name: 'Lms::Enrollment', inverse_of: :course, dependent: :destroy
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :updated_by, class_name: 'User', optional: true

  normalizes :title, :summary, :badge_title, with: ->(value) { value.to_s.squish.presence }
  normalizes :slug, with: ->(value) { value.to_s.strip.downcase }

  validates :tenant_id, :title, presence: true
  validates :title, length: { maximum: 160 }
  validates :summary, length: { maximum: 300 }
  validates :slug, presence: true, format: { with: SLUG_FORMAT }, length: { maximum: 80 }, uniqueness: { scope: :tenant_id }
  validates :status, inclusion: { in: STATUSES }
  validates :locale, presence: true, length: { maximum: 8 }

  scope :published, -> { where(status: 'published') }
  scope :ordered, -> { order(:position, :title, :id) }

  def to_param = slug
  def published? = status == 'published'
  def name = title
  def minutes = lessons.sum(&:minutes)

  # The glossary as `key => [term, definition]`, the shape `define` helpers expect.
  def glossary
    @glossary ||= glossary_terms.each_with_object({}) { |term, hash| hash[term.key] = [term.term, term.definition] }
  end

  def lesson_after(lesson)
    list = lessons.to_a
    index = list.index(lesson)
    index && list[index + 1]
  end

  def lesson_before(lesson)
    list = lessons.to_a
    index = list.index(lesson)
    index&.positive? ? list[index - 1] : nil
  end

  # Marks that a person changed what learners read, so the seeder stops overwriting it.
  def touch_edited!(actor)
    update_columns(edited_at: Time.current, updated_by_id: actor&.id, updated_at: Time.current)
  end
end
