# frozen_string_literal: true

# One line of a training assignment's history, read from the shared work-item history (Work::ItemEvent, #407 #409):
# who did what, when, from which status to which, against which revision of the module. Append-only (a saved row is
# read-only and cannot be destroyed or deleted). Rows are written by Work::Tracked when an assignment is created or
# moves (TrainingAssignment.assign!, TrainingAssignment#transition!), in the same transaction.
#
# Training words for the shared actions: created → assigned; transitioned by start/complete/cancel →
# started/completed/cancelled. Rows copied from the old training_assignment_events table keep its id in
# details['legacy_event_id'].
class TrainingAssignmentEvent < Work::ItemEvent
  ACTIONS = %w[assigned started completed cancelled].freeze
  LABELS = { 'assigned' => 'Assigned', 'started' => 'Started', 'completed' => 'Completed', 'cancelled' => 'Cancelled' }.freeze
  TRANSITION_ACTIONS = { 'start' => 'started', 'complete' => 'completed', 'cancel' => 'cancelled' }.freeze

  default_scope { where(item_kind: TrainingAssignment::KIND) }

  belongs_to :training_assignment, foreign_key: :work_item_id, inverse_of: :events
  # The old table's column name, so queries written against it keep working.
  alias_attribute :training_assignment_id, :work_item_id

  # assigned, started, completed or cancelled.
  def training_action
    return 'assigned' if action == 'created'

    TRANSITION_ACTIONS.fetch(transition.to_s) { action }
  end

  def label = LABELS.fetch(training_action) { super }
  def module_revision = details['module_revision']
end
