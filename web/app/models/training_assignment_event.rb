# frozen_string_literal: true

# One line of a training assignment's history: who did what, when, from which status to which, against which revision
# of the module. Append-only: a saved row is read-only and cannot be destroyed or deleted. Rows are written only by
# TrainingAssignment (assign! and transition!). The shape (actor, action, from/to status, created_at) is generic so it
# can become the shared Project table's history (#407).
class TrainingAssignmentEvent < ApplicationRecord
  include TenantScoped

  ACTIONS = %w[assigned started completed cancelled].freeze
  LABELS = { 'assigned' => 'Assigned', 'started' => 'Started', 'completed' => 'Completed', 'cancelled' => 'Cancelled' }.freeze

  belongs_to :training_assignment, inverse_of: :events
  belongs_to :actor, class_name: 'User', optional: true

  validates :tenant_id, :actor_name, :to_status, :module_revision, presence: true
  validates :action, inclusion: { in: ACTIONS }
  validates :to_status, inclusion: { in: TrainingAssignment::STATUSES }
  validates :note, length: { maximum: 500 }
  validate { errors.add(:training_assignment, 'must belong to this workspace') unless training_assignment&.tenant_id == tenant_id }

  before_destroy(prepend: true) { throw :abort }

  def label = LABELS.fetch(action, action.humanize)

  def readonly?
    persisted? || super
  end

  def delete
    raise ActiveRecord::ReadOnlyRecord, 'Training history is append-only.' if persisted?

    super
  end
end
