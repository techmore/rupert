# frozen_string_literal: true

module Work
  # One line of a work item's history: who did what, when, from which status to which, and which fields changed.
  # Append-only: a saved row is read-only and cannot be destroyed or deleted. Rows are written by Work::Tracked in
  # the same transaction as the change. There is no foreign key to the item, so a deleted item's history stays.
  class ItemEvent < ApplicationRecord
    include TenantScoped

    self.table_name = 'work_item_events'

    ACTIONS = %w[created updated assigned rescheduled transitioned deleted].freeze
    LABELS = {
      'created' => 'Created', 'updated' => 'Changed', 'assigned' => 'Assigned', 'rescheduled' => 'Due date changed',
      'transitioned' => 'Status changed', 'deleted' => 'Deleted'
    }.freeze

    belongs_to :actor, class_name: 'User', optional: true

    attribute :field_changes, :json, default: -> { {} }
    # Facts the kind keeps about the moment (Work::Kind#event_details; training: the module revision).
    attribute :details, :json, default: -> { {} }

    validates :tenant_id, :work_item_id, :actor_name, presence: true
    validates :action, inclusion: { in: ACTIONS }
    validates :item_kind, inclusion: { in: ->(_) { Work::Registry.keys } }
    validates :note, length: { maximum: 500 }

    before_destroy(prepend: true) { throw :abort }

    scope :timeline, -> { order(:created_at, :id) }
    scope :for_item, ->(item) { where(work_item_id: item.id) }

    def details = super || {}

    def label = LABELS.fetch(action, action.humanize)

    def readonly?
      persisted? || super
    end

    def delete
      raise ActiveRecord::ReadOnlyRecord, 'Work history is append-only.' if persisted?

      super
    end
  end
end
