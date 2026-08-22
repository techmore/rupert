# frozen_string_literal: true

module People
  # A department in the org chart. Has a manager (an Employee) and positions.
  class Department < ApplicationRecord
    include TenantScoped

    self.table_name = 'departments'

    belongs_to :manager, class_name: 'People::Employee', optional: true
    has_many :positions, class_name: 'People::Position', dependent: :nullify
    has_many :employees, class_name: 'People::Employee', dependent: :nullify

    validates :name, presence: true, uniqueness: { scope: :tenant_id }

    scope :ordered, -> { order(:name) }
  end
end
