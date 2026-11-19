# frozen_string_literal: true

# A tap-to-define word for one course. Lessons reference it as [[key]] (Lms::Markup).
class Lms::GlossaryTerm < ApplicationRecord
  include TenantScoped

  belongs_to :course, class_name: 'Lms::Course', inverse_of: :glossary_terms

  normalizes :key, with: ->(value) { value.to_s.strip.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_|_\z/, '') }
  normalizes :term, with: ->(value) { value.to_s.squish }
  normalizes :definition, with: ->(value) { value.to_s.strip }

  validates :tenant_id, :key, :term, :definition, presence: true
  validates :key, uniqueness: { scope: :course_id }, length: { maximum: 60 }
  validates :term, length: { maximum: 80 }
  validates :definition, length: { maximum: 600 }
end
