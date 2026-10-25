# frozen_string_literal: true

module Work
  # What every record in the shared work-item table shares, whichever class reads it (Work::Item for all kinds,
  # Projects::Task for kind 'task'): the kind lookup, the started time, and an append-only history row for every
  # create, tracked change, status change and delete, written in the same transaction as the change.
  module Tracked
    extend ActiveSupport::Concern

    # Board order, reminder bookkeeping and the timestamps the status already implies are not history.
    UNTRACKED = %w[id tenant_id kind created_at updated_at position next_spawned_at started_at completed_at].freeze

    included do
      attribute :details, :json, default: -> { {} }

      alias_attribute :body, :description

      before_save :stamp_started_at
      after_create { record_work_event!('created', to_status: status) }
      after_update :record_work_changes
      after_destroy { record_work_event!('deleted', from_status: status) }
    end

    # Rows written before details existed hold NULL.
    def details = super || {}

    # Who the next history row is for, when it is not Current.user (Work::Item#transition! sets it).
    attr_writer :work_actor

    def work_actor = @work_actor || Current.user

    def kind_definition = Work::Registry.fetch(kind)

    def history = Work::ItemEvent.where(tenant_id: tenant_id).for_item(self).timeline

    def work_path = kind_definition.path&.call(self)

    private

    def stamp_started_at
      return unless will_save_change_to_status? && Work::Registry.known?(kind)

      self.started_at ||= Time.current if kind_definition.started_statuses.include?(status)
    end

    def record_work_changes
      changes = saved_changes.except(*UNTRACKED)
      return if changes.empty?

      action = work_action_for(changes.keys)
      from, to = changes['status']
      record_work_event!(action, from_status: from || status, to_status: to || status, field_changes: changes.except('status'))
    end

    def work_action_for(keys)
      return 'transitioned' if keys.include?('status')
      return 'assigned' if keys == ['assignee_id']
      return 'rescheduled' if keys == ['due_on']

      'updated'
    end

    def record_work_event!(action, from_status: nil, to_status: nil, field_changes: {})
      actor = work_actor
      Work::ItemEvent.create!(
        tenant_id: tenant_id, work_item_id: id, item_kind: kind, action: action, transition: current_transition_name,
        from_status: from_status, to_status: to_status, actor_id: actor&.id,
        actor_name: actor&.display_name.presence || actor&.email || 'system', field_changes: printable(field_changes),
        note: work_event_note(action, to_status), details: work_event_details
      )
    end

    def work_event_note(action, to_status)
      return @work_note if action == 'transitioned' && @work_note.present?

      blocked_reason.to_s.first(500).presence if respond_to?(:blocked_reason) && to_status == 'blocked' && action == 'transitioned'
    end

    # Facts the kind keeps on each history row (training: the module revision), or none.
    def work_event_details
      hook = Work::Registry.known?(kind) && kind_definition.event_details
      hook ? hook.call(self).to_h.compact : {}
    end

    # The event that is firing, when the record has a state machine (AASM) or Work::Item#transition! set one.
    def current_transition_name
      name = @work_transition || (aasm.current_event if respond_to?(:aasm))
      name&.to_s&.delete_suffix('!')
    end

    # Dates as ISO text; long text is cut so history stays small (the record keeps the full text).
    def printable(changes)
      changes.transform_values do |pair|
        pair.map do |value|
          case value
          when Date, Time then value.iso8601
          when String then value.length > 300 ? "#{value.first(300)}…" : value
          else value
          end
        end
      end
    end
  end
end
