# frozen_string_literal: true

# One training module assigned to one person, with an optional due date (#410).
#
#   assigned ──start──▶ in_progress ──complete──▶ completed
#      └──────────cancel (manager)──────┴──▶ cancelled
#
# Only the assignee starts and completes; a manager with hr.write assigns and cancels. Status changes only through
# `transition!`, which writes a TrainingAssignmentEvent in the same transaction, so the history is the full story.
# A completed assignment is the record a future training bonus binds to (#412): who, when, and which revision of the
# module. Nothing here touches pay.
#
# The columns match a task's (assignee_id, due_on, status, started_at, completed_at) so this can fold into the shared
# Project table (#407 #409) as a "training" work type with these transitions.
class TrainingAssignment < ApplicationRecord
  include TenantScoped

  STATUSES = %w[assigned in_progress completed cancelled].freeze
  OPEN_STATUSES = %w[assigned in_progress].freeze
  STATUS_LABELS = { 'assigned' => 'Assigned', 'in_progress' => 'In progress', 'completed' => 'Completed', 'cancelled' => 'Cancelled' }.freeze
  # event => [from statuses, to status, who may do it]
  TRANSITIONS = {
    'start' => [%w[assigned], 'in_progress', :assignee],
    'complete' => [%w[in_progress], 'completed', :assignee],
    'cancel' => [%w[assigned in_progress], 'cancelled', :manager]
  }.freeze
  EVENT_ACTIONS = { 'start' => 'started', 'complete' => 'completed', 'cancel' => 'cancelled' }.freeze

  class TransitionRefused < StandardError; end

  belongs_to :training_module, inverse_of: :assignments
  belongs_to :assignee, class_name: 'User'
  belongs_to :assigned_by, class_name: 'User', optional: true
  belongs_to :completed_by, class_name: 'User', optional: true
  has_many :events, -> { order(:created_at, :id) }, class_name: 'TrainingAssignmentEvent', inverse_of: :training_assignment,
    dependent: :restrict_with_exception

  attr_readonly :tenant_id, :training_module_id, :assignee_id

  validates :tenant_id, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :same_tenant_records
  validate :status_changed_by_transition, on: :update
  validate :one_open_assignment, on: :create

  before_destroy(prepend: true) { throw :abort }

  scope :open_items, -> { where(status: OPEN_STATUSES) }
  scope :completed, -> { where(status: 'completed') }
  scope :overdue, -> { open_items.where(due_on: ...Date.current) }
  scope :for_user, ->(user) { where(tenant_id: user.tenant_id, assignee_id: user.id) }
  scope :by_due, -> { order(Arel.sql('CASE WHEN training_assignments.due_on IS NULL THEN 1 ELSE 0 END'), :due_on, :id) }

  class << self
    # Assigns the module to each person who has no open assignment for it yet. Returns [created, skipped].
    def assign!(training_module, people, due_on:, actor:)
      created = []
      skipped = []
      people.uniq.each do |person|
        transaction do
          assignment = create!(training_module: training_module, tenant_id: training_module.tenant_id, assignee: person,
            assigned_by: actor, due_on: due_on, status: 'assigned')
          assignment.record_event!('assigned', from: nil, actor: actor)
          created << assignment
        end
      rescue ActiveRecord::RecordInvalid => e
        raise unless e.record.errors.of_kind?(:base, :already_open)

        skipped << person
      end
      [created, skipped]
    end
  end

  def status_label = STATUS_LABELS.fetch(status, status.humanize)
  def open? = OPEN_STATUSES.include?(status)
  def completed? = status == 'completed'
  def overdue? = open? && due_on.present? && due_on < Date.current

  def may?(event, user)
    from, _to, who = TRANSITIONS[event.to_s]
    return false unless from&.include?(status) && user&.active? && user.tenant_id == tenant_id

    who == :assignee ? assignee_id == user.id : user.can?('hr.write')
  end

  # Moves the assignment through one event and appends the history row, under a row lock.
  def transition!(event, actor:, note: nil)
    with_lock do
      raise TransitionRefused, refusal_for(event, actor) unless may?(event, actor)

      from = status
      _from, to, _who = TRANSITIONS.fetch(event.to_s)
      now = Time.current
      self.status = to
      self.started_at ||= now if to == 'in_progress'
      if to == 'completed'
        self.completed_at = now
        self.completed_by = actor
        self.completed_revision = training_module.revision
      end
      self.cancelled_at = now if to == 'cancelled'
      @transitioning = true
      save!
      record_event!(EVENT_ACTIONS.fetch(event.to_s), from: from, actor: actor, note: note)
    ensure
      @transitioning = false
    end
    self
  end

  def record_event!(action, from:, actor:, note: nil)
    events.create!(tenant_id: tenant_id, actor: actor, actor_name: actor&.display_name.presence || actor&.email || 'system', action: action,
      from_status: from, to_status: status, module_revision: training_module.revision, note: note.to_s.strip.first(500).presence)
  end

  def refusal_for(event, actor)
    from, _to, who = TRANSITIONS[event.to_s]
    return 'That is not a training action.' unless from
    return 'Only the person it is assigned to can do that.' if who == :assignee && assignee_id != actor&.id
    return 'Only a manager with staff editing can do that.' if who == :manager && !actor&.can?('hr.write')

    "Cannot #{event} training that is #{status_label.downcase}."
  end

  private

  def same_tenant_records
    errors.add(:training_module, 'must belong to this workspace') unless training_module && training_module.tenant_id == tenant_id
    people = User.where(tenant_id: tenant_id, id: assignee_id)
    people = people.active if new_record?
    errors.add(:assignee, 'must be an active person in this workspace') unless assignee_id && people.exists?
  end

  def status_changed_by_transition
    errors.add(:status, 'changes only through a training action') if will_save_change_to_status? && !@transitioning
  end

  def one_open_assignment
    return unless training_module && assignee_id

    scope = self.class.unscoped.where(tenant_id: tenant_id, training_module_id: training_module.id, assignee_id: assignee_id).open_items
    errors.add(:base, :already_open, message: 'This person already has this training open') if scope.exists?
  end
end
