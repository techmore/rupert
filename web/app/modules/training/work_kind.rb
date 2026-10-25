# frozen_string_literal: true

module Training
  # The training kind of the shared work-item table (#407 phase 2b, #409; docs/architecture/shared-work-items.md):
  # one TrainingModule assigned to one person. `source` is the module, `requester` who assigned it, `assignee` the
  # trainee. The transitions are the ones the old TrainingAssignment::TRANSITIONS table had, unchanged:
  #
  #   assigned ──start (assignee only)──▶ in_progress ──complete (assignee only)──▶ completed
  #      └──────────────cancel (hr.write)──────────┴──▶ cancelled
  #
  # Nobody starts or completes training for someone else. Completing stores who and which module revision in
  # details; every history row stores the module revision the step was taken against. Read with hr.read, managed
  # with hr.write; everyone else (staff included) sees only their own (Training::AssignmentPolicy).
  module WorkKind
    KEY = 'training_assignment'
    ACTIVITY = { 'start' => 'training_started', 'complete' => 'training_completed', 'cancel' => 'training_assignment_cancelled' }.freeze

    module_function

    def kind
      Work::Kind.new(
        key: KEY, label: 'Training', policy: 'Training::AssignmentPolicy', activity_prefix: 'training',
        statuses: %w[assigned in_progress completed cancelled], initial_status: 'assigned', started_statuses: %w[in_progress],
        done_statuses: %w[completed cancelled],
        transitions: {
          'start' => { from: %w[assigned], to: 'in_progress', who: :assignee_only },
          'complete' => { from: %w[in_progress], to: 'completed', who: :assignee_only },
          'cancel' => { from: %w[assigned in_progress], to: 'cancelled', who: :manager }
        },
        fields: { 'completed_revision' => { type: :integer }, 'completed_by_id' => { type: :integer }, 'legacy_id' => { type: :integer } },
        permissions: { read: 'hr.read', write: 'hr.write' },
        path: method(:path_for),
        calendar: :due,
        prepare: method(:prepare),
        check: method(:check),
        event_details: ->(item) { { 'module_revision' => training_module(item)&.revision } },
        activity: method(:log_transition)
      )
    end

    def training_module(item)
      return unless item.source_type == 'TrainingModule' && item.source_id

      item.try(:training_module) || item.source
    end

    # A manager opens the module's Assignments table; the trainee opens their own assignment page.
    def path_for(item)
      helpers = Rails.application.routes.url_helpers
      user = Current.user
      if user && item.assignee_id.to_s == user.id.to_s && (user.employee? || !user.can?('hr.read'))
        helpers.employee_training_path(item)
      else
        helpers.training_module_path(item.source_id, anchor: 'assignments')
      end
    end

    def prepare(item)
      item.source_type = 'TrainingModule' if item.source_type.blank? && item.source_id.present?
      training = training_module(item)
      item.title = training.title if item.title.blank? && training
      return unless item.persisted? && item.will_save_change_to_status? && item.status == 'completed'

      item.details = item.details.merge('completed_revision' => training&.revision, 'completed_by_id' => item.work_actor&.id).compact
    end

    def check(item)
      tenant_id = item.tenant_id || Current.tenant_id
      valid = item.source_type == 'TrainingModule' && TrainingModule.tenant_unscoped(tenant_id).exists?(id: item.source_id)
      item.errors.add(:training_module, 'must belong to this workspace') unless valid
      item.errors.add(:assignee, 'must be an active person in this workspace') if item.assignee_id.blank?
      item.errors.add(:parent, 'is not used for training') if item.parent_id.present?
    end

    # The Activity log keeps the names training used before the shared table, about the module.
    def log_transition(item, event, user, note)
      training = training_module(item)
      details = case event
                when 'cancel' then [item.assignee&.display_name, note.to_s.squish.first(500).presence].compact.join('; ')
                else "Revision #{training&.revision}"
                end
      ActivityLogger.log(ACTIVITY.fetch(event, "training_#{event}"), subject: training || item, actor: user, details: details)
    end
  end
end
