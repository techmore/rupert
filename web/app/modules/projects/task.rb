# frozen_string_literal: true

module Projects
  class Task < ApplicationRecord
    include TenantScoped
    include UuidId
    include AASM

    self.table_name = "tasks"

    PRIORITIES = ["low", "medium", "high", "urgent"].freeze

    belongs_to :project, class_name: "Projects::Project", foreign_key: :project_id, optional: true
    belongs_to :assignee, class_name: "User", foreign_key: :assignee_id, optional: true

    validates :title, presence: true
    validates :priority, inclusion: { in: PRIORITIES }

    scope :recent, ->(limit = 20) { order(updated_at: :desc).limit(limit) }
    scope :open, -> { where(status: ["todo", "in_progress"]) }
    scope :completed, -> { where(status: "done") }

    aasm column: "status", no_direct_assignment: true do
      state :todo, initial: true
      state :in_progress
      state :done
      state :blocked

      event :start do
        transitions from: :todo, to: :in_progress
      end
      event :finish do
        transitions from: [:in_progress, :todo, :blocked], to: :done
        after { self.completed_at = Time.current }
      end
      event :block do
        transitions from: [:todo, :in_progress], to: :blocked
      end
      event :reopen do
        transitions from: [:done, :blocked], to: :todo
        after { self.completed_at = nil }
      end
    end
  end
end
