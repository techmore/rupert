# frozen_string_literal: true

# One training module assigned to one person, with an optional due date (#410). A row of the shared work-item table
# (#407 #409, docs/architecture/shared-work-items.md): kind 'training_assignment', `source` = the TrainingModule,
# `requester` = who assigned it, `details` = { completed_revision, completed_by_id, legacy_id }.
#
#   assigned ──start──▶ in_progress ──complete──▶ completed
#      └──────────cancel (manager)──────┴──▶ cancelled
#
# The kind (Training::WorkKind) holds the transitions: only the assignee starts and completes; a manager with hr.write
# assigns and cancels. Status changes only through `transition!` (Work::Item#transition!, under a row lock), which
# writes a history row (Work::ItemEvent, read here as TrainingAssignmentEvent) in the same transaction.
# A completed assignment is the record a future training bonus binds to (#412): who, when, and which revision of the
# module. Nothing here touches pay.
#
# Rows copied from the old training_assignments table keep that table's id in details['legacy_id'] and the old row
# records the new id (TrainingAssignment::Legacy#work_item_id), so old links redirect.
class TrainingAssignment < Work::Item
  KIND = 'training_assignment'
  STATUSES = %w[assigned in_progress completed cancelled].freeze
  OPEN_STATUSES = %w[assigned in_progress].freeze
  STATUS_LABELS = { 'assigned' => 'Assigned', 'in_progress' => 'In progress', 'completed' => 'Completed', 'cancelled' => 'Cancelled' }.freeze

  default_scope { where(kind: KIND) }

  belongs_to :training_module, foreign_key: :source_id, inverse_of: :assignments, optional: true
  has_many :events, -> { order(:created_at, :id) }, class_name: 'TrainingAssignmentEvent', foreign_key: :work_item_id,
    inverse_of: :training_assignment, dependent: :restrict_with_exception

  attribute :kind, :string, default: KIND
  attribute :source_type, :string, default: 'TrainingModule'
  attr_readonly :tenant_id, :kind, :source_type, :source_id, :assignee_id

  validate :one_open_assignment, on: :create

  before_destroy(prepend: true) { throw :abort }

  scope :completed, -> { where(status: 'completed') }
  scope :overdue, -> { open_items.where(due_on: ...Date.current) }
  scope :for_user, ->(user) { where(tenant_id: user.tenant_id, assignee_id: user.id.to_s) }
  scope :by_due, -> { order(Arel.sql('CASE WHEN tasks.due_on IS NULL THEN 1 ELSE 0 END'), :due_on, :id) }

  class << self
    # `unscoped` drops the workspace filter but keeps the kind: this class only ever reads training rows, so code that
    # crosses workspaces (the setup checklist, tests) can never see tasks or marketing items through it.
    def unscoped(&block)
      return super.where(kind: KIND) unless block

      super { where(kind: KIND).scoping(&block) }
    end

    # Assigns the module to each person who has no open assignment for it yet. Returns [created, skipped].
    def assign!(training_module, people, due_on:, actor:)
      created = []
      skipped = []
      people.uniq.each do |person|
        transaction do
          assignment = new(training_module: training_module, tenant_id: training_module.tenant_id, assignee: person, requester: actor,
            due_on: due_on)
          assignment.work_actor = actor
          assignment.save!
          created << assignment
        end
      rescue ActiveRecord::RecordInvalid => e
        raise unless e.record.errors.of_kind?(:base, :already_open)

        skipped << person
      end
      [created, skipped]
    end
  end

  def assigned_by = requester
  def assigned_by_id = requester_id&.to_i
  def completed_revision = details['completed_revision']
  def completed_by_id = details['completed_by_id']
  def completed_by = completed_by_id && User.find_by(id: completed_by_id)
  def legacy_id = details['legacy_id']
  def cancelled_at = (completed_at if status == 'cancelled')

  def status_label = STATUS_LABELS.fetch(status, status.humanize)
  def open? = OPEN_STATUSES.include?(status)
  def completed? = status == 'completed'
  def overdue? = open? && due_on.present? && due_on < Date.current

  def may?(event, user) = may_transition?(event, user)

  # Moves the assignment through one event (Work::Item#transition!: row lock, history row, Activity log entry).
  def transition!(event, actor: Current.user, user: nil, note: nil)
    actor ||= user
    raise TransitionRefused, refusal_for(event, actor) unless may?(event, actor)

    super(event, user: actor, note: note)
    self
  end

  def refusal_for(event, actor = Current.user)
    spec = kind_definition.transition(event)
    return 'That is not a training action.' unless spec
    return 'Only the person it is assigned to can do that.' if spec[:who] == :assignee_only && assignee_id.to_s != actor&.id.to_s
    return 'Only a manager with staff editing can do that.' if spec[:who] == :manager && !actor&.can?('hr.write')

    "Cannot #{event} training that is #{status_label.downcase}."
  end

  private

  def status_changed_by_transition
    return unless will_save_change_to_status? && !@transitioning

    errors.add(:status, 'changes only through a training action')
  end

  def one_open_assignment
    return unless training_module && assignee_id

    scope = self.class.tenant_unscoped(tenant_id).where(source_type: 'TrainingModule', source_id: training_module.id,
      assignee_id: assignee_id.to_s, status: OPEN_STATUSES)
    errors.add(:base, :already_open, message: 'This person already has this training open') if scope.exists?
  end
end
