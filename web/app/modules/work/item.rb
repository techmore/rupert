# frozen_string_literal: true

module Work
  # A row of the shared work-item table (#407), of any registered kind. The physical table keeps its original name,
  # `tasks`, so existing task ids, URLs and foreign keys are unchanged (docs/architecture/shared-work-items.md).
  #
  # Common columns: tenant_id, kind, title, description (also `body`), status, priority, assignee_id, requester_id,
  # start_on, due_on, started_at, completed_at, parent_id, source (polymorphic), position, details (JSON, checked
  # against the kind's field list). Task-only columns from before the shared table (project_id, labels,
  # blocked_reason, recurrence, estimate_minutes, next_spawned_at) stay where they are.
  #
  # Use Work::Item to read across kinds (one calendar, "my work") and to run kinds that have no workflow class of
  # their own. A kind with a workflow class (task → Projects::Task) is written through that class; Work::Item
  # refuses to save it and hands transitions to it.
  class Item < ApplicationRecord
    include TenantScoped
    include Work::Tracked

    self.table_name = 'tasks'

    PRIORITIES = %w[low medium high urgent].freeze

    class TransitionRefused < StandardError; end

    belongs_to :assignee, class_name: 'User', optional: true
    belongs_to :requester, class_name: 'User', optional: true
    belongs_to :parent, class_name: 'Work::Item', optional: true
    belongs_to :source, polymorphic: true, optional: true
    has_many :children, class_name: 'Work::Item', foreign_key: :parent_id, inverse_of: :parent, dependent: :restrict_with_error

    validates :title, presence: true, length: { maximum: 200 }
    validates :description, length: { maximum: 50_000 }
    validates :priority, inclusion: { in: PRIORITIES }, allow_nil: true
    validate :kind_registered
    validate :kind_rules, if: :known_kind?
    validate :people_in_workspace
    validate :parent_in_workspace
    validate :status_changed_by_transition, on: :update

    # A new item starts in its kind's first status unless one was given (the column default belongs to tasks).
    before_validation(on: :create) { self.status = kind_definition.initial_status if known_kind? && (status.blank? || !status_changed?) }
    # A kind may derive shared columns from its own fields (an event's start_on/due_on from its local start and end).
    before_validation { kind_definition.prepare&.call(self) if known_kind? && !kind_definition.bespoke? }

    scope :of_kind, ->(key) { where(kind: key.to_s) }
    scope :assigned_to, ->(user_id) { where(assignee_id: user_id.to_s) }
    scope :due_between, ->(range) { where(due_on: range) }
    scope :open_items, lambda {
      done = Work::Registry.kinds.values.flat_map(&:done_statuses).uniq
      where.not(status: done)
    }

    def known_kind? = Work::Registry.known?(kind)

    # The record as its kind's own workflow class sees it (a Projects::Task for kind 'task'), or self.
    def specific
      return self unless known_kind? && kind_definition.bespoke? && !is_a?(kind_definition.model_class)

      kind_definition.model_class.find(id)
    end

    def may_transition?(event, user = Current.user)
      spec = kind_definition.transition(event)
      return false unless spec && kind_definition.allows?(event, status)

      policy = kind_definition.policy_class.new(user, specific)
      return false unless policy.respond_to?(:transition?) ? policy.transition? : policy.update?

      case spec[:who]
      when :assignee then assignee_id.to_s == user&.id.to_s || manager?(user)
      when :manager then manager?(user)
      else true
      end
    end

    # Fires `event` as `user`, under a row lock. Refused (TransitionRefused, nothing saved) when the kind has no
    # such event from the current status or the person may not fire it. Writes one history row and an Activity log
    # entry ("<kind>_transitioned").
    def transition!(event, user: Current.user, note: nil)
      event = event.to_s
      with_lock do
        raise TransitionRefused, refusal_for(event) unless may_transition?(event, user)

        record = specific
        record.work_actor = user
        if record.equal?(self)
          spec = kind_definition.transition(event)
          @work_transition = event
          self.status = spec[:to]
          self.completed_at = kind_definition.done_statuses.include?(spec[:to]) ? Time.current : nil
          @transitioning = true
          save!
        else
          raise TransitionRefused, record.refusal_for(event) unless record.public_send(:"may_#{event}?")

          event == 'block' && record.respond_to?(:block_with_reason!) ? record.block_with_reason!(note) : record.public_send(:"#{event}!")
          reload
        end
      ensure
        @transitioning = false
        @work_transition = nil
        @work_actor = nil
      end
      ActivityLogger.log("#{kind_definition.activity_prefix}_transitioned", subject: self, actor: user,
        details: ["Status: #{status}", note.to_s.squish.first(500).presence].compact.join('; '))
      true
    end

    def refusal_for(event)
      return "There is no #{event.to_s.humanize.downcase} step for a #{kind_definition.label.downcase}." unless kind_definition.transition(event)
      return "Cannot #{event.to_s.humanize.downcase} a #{status.to_s.humanize.downcase} #{kind_definition.label.downcase}." unless kind_definition.allows?(event, status)

      'You are not allowed to do that.'
    end

    def name = title

    private

    def manager?(user)
      user&.active? && !user.employee? && user.tenant_id.to_s == tenant_id.to_s && user.can?(kind_definition.permissions[:write])
    end

    def kind_registered
      errors.add(:kind, 'is not a known kind of work') unless known_kind?
    end

    def kind_rules
      definition = kind_definition
      if definition.bespoke? && !is_a?(definition.model_class)
        errors.add(:base, "#{definition.label.pluralize} are saved through #{definition.model}")
        return
      end
      errors.add(:status, 'is not a status of this kind') unless definition.statuses.include?(status.to_s)
      definition.validate_details(self, details)
      definition.check&.call(self)
    end

    def status_changed_by_transition
      return unless will_save_change_to_status? && !@transitioning && !(known_kind? && kind_definition.bespoke?)

      errors.add(:status, 'changes only through a transition')
    end

    def people_in_workspace
      %i[assignee_id requester_id].each do |attribute|
        value = public_send(attribute)
        next if value.blank?
        next if User.where(tenant_id: tenant_id || Current.tenant_id).active.exists?(id: value)

        errors.add(attribute, 'must be an active person in this workspace')
      end
    end

    def parent_in_workspace
      return if parent_id.blank?

      errors.add(:parent, 'cannot be the item itself') if persisted? && parent_id == id
      errors.add(:parent, 'was not found') unless Work::Item.unscoped.exists?(id: parent_id, tenant_id: tenant_id || Current.tenant_id)
    end
  end
end
