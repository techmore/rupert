# frozen_string_literal: true

module Projects
  class Project < ApplicationRecord
    include TenantScoped
    include AASM

    self.table_name = 'projects'

    belongs_to :owner, class_name: 'User', foreign_key: :owner_id, optional: true
    has_many :tasks, class_name: 'Projects::Task', foreign_key: :project_id, dependent: :destroy

    validates :name, presence: true

    scope :recent, ->(limit = 20) { order(updated_at: :desc).limit(limit) }

    aasm column: 'status', no_direct_assignment: true do
      state :planned, initial: true
      state :active
      state :on_hold
      state :completed
      state :archived

      event :start do
        transitions from: %i[planned on_hold], to: :active
      end
      event :hold do
        transitions from: :active, to: :on_hold
      end
      event :complete do
        transitions from: %i[active on_hold], to: :completed
      end
      event :archive do
        transitions from: %i[completed planned active on_hold], to: :archived
      end
    end

    def progress_pct
      total = tasks.count
      return 0 if total.zero?

      (tasks.completed.count.to_f / total * 100).round
    end
  end
end
