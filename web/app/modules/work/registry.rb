# frozen_string_literal: true

module Work
  # The kinds of tracked work that live in the shared work-item table (#407): 'task' (phase 1), and the marketing
  # kinds 'marketing_event' and 'campaign_task' (#415, Marketing::WorkKinds). Later phases add request and
  # training_assignment (docs/architecture/shared-work-items.md). A row whose kind is not registered cannot be saved.
  module Registry
    class UnknownKind < KeyError; end

    module_function

    def kinds
      @kinds ||= defaults.index_by(&:key)
    end

    def fetch(key)
      kinds.fetch(key.to_s) { raise UnknownKind, "Unknown work item kind: #{key.inspect}" }
    end

    def known?(key) = kinds.key?(key.to_s)
    def keys = kinds.keys

    # For tests and later phases; a kind key is registered once.
    def register(kind)
      raise ArgumentError, "kind #{kind.key} is already registered" if kinds.key?(kind.key)

      kinds[kind.key] = kind
    end

    def unregister(key)
      raise ArgumentError, 'built-in kinds cannot be removed' if defaults.any? { |kind| kind.key == key.to_s }

      kinds.delete(key.to_s)
    end

    def defaults
      [task_kind, Marketing::WorkKinds.event_kind, Marketing::WorkKinds.campaign_task_kind]
    end

    # Kinds that appear on the shared calendar (#417).
    def calendar_kinds = kinds.values.select(&:calendar)

    # Projects::Task keeps its AASM state machine (dependency guards, recurrence, board moves); the registry reads
    # the transition table from it so the two can never disagree.
    def task_kind
      Kind.new(
        key: 'task', label: 'Task', model: 'Projects::Task', policy: 'Projects::TaskPolicy', activity_prefix: 'task',
        statuses: %w[todo in_progress blocked done], initial_status: 'todo', started_statuses: %w[in_progress], done_statuses: %w[done],
        transitions: -> { aasm_transitions(Projects::Task) },
        permissions: { read: 'projects.read', write: 'projects.write', self_service: 'tasks.self' },
        path: ->(item) { Rails.application.routes.url_helpers.projects_task_path(item) },
        calendar: :due
      )
    end

    def aasm_transitions(model)
      model.aasm.events.to_h do |event|
        targets = event.transitions.map { |transition| transition.to.to_s }.uniq
        [event.name.to_s, { from: event.transitions.map { |transition| transition.from.to_s }.uniq, to: targets.sole, who: :writer }]
      end
    end
  end
end
