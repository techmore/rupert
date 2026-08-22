# frozen_string_literal: true

module People
  # A job position (title) with an optional department and pay grade.
  class Position < ApplicationRecord
    include TenantScoped

    self.table_name = 'positions'

    belongs_to :department, class_name: 'People::Department', optional: true
    has_many :employees, class_name: 'People::Employee', dependent: :nullify

    validates :name, presence: true

    scope :ordered, -> { order(:name) }
  end
end
