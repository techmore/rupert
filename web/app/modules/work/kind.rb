# frozen_string_literal: true

module Work
  # One kind of tracked work (a task today; requests, training assignments and marketing events in later phases,
  # see docs/architecture/shared-work-items.md). A kind says which statuses its items move through, which events
  # move them and who may fire each, which kind-specific fields live in the item's `details` JSON, and which
  # permissions read and write it.
  #
  # transitions: { 'start' => { from: %w[todo], to: 'in_progress', who: :writer }, ... }
  #   who: :writer   — anyone the kind's policy lets update the item
  #        :assignee — only the item's assignee (or a writer acting for them)
  #        :manager  — only someone with the kind's write permission
  # fields: { 'venue' => { type: :string, max: 200, required: false }, ... }
  #   types: :string, :text, :integer, :boolean, :date, :url
  # started_statuses: entering one of these first stamps started_at; done_statuses: these stamp completed_at.
  # model: a class that owns the kind's workflow (Projects::Task for 'task'). Writes for such a kind go through that
  #   class so its own rules (dependencies, recurrence, row locks) apply; Work::Item only reads them.
  Kind = Data.define(:key, :label, :model, :statuses, :initial_status, :started_statuses, :done_statuses, :transitions, :fields, :permissions,
    :policy, :activity_prefix, :path)

  class Kind
    FIELD_TYPES = %i[string text integer boolean date url].freeze

    def initialize(key:, label:, statuses:, initial_status:, transitions:, permissions:, model: nil, started_statuses: [], done_statuses: [], fields: {},
      policy: nil, activity_prefix: nil, path: nil)
      fields = fields.to_h { |name, spec| [name.to_s, spec] }
      bad = fields.reject { |_, spec| FIELD_TYPES.include?(spec[:type]) }
      raise ArgumentError, "unknown field type for #{bad.keys.to_sentence}" if bad.any?

      super(key: key.to_s, label:, model:, statuses: statuses.map(&:to_s), initial_status: initial_status.to_s,
        started_statuses: started_statuses.map(&:to_s), done_statuses: done_statuses.map(&:to_s), transitions:, fields:, permissions:, policy:,
        activity_prefix: (activity_prefix || key).to_s, path:)
    end

    def model_class = model&.constantize
    def policy_class = (policy || 'Work::ItemPolicy').constantize
    def bespoke? = model.present?

    # transitions may be a hash or a lambda (so a kind can read them from its model's state machine lazily).
    def transition_table
      table = transitions.respond_to?(:call) ? transitions.call : transitions
      table.to_h { |event, spec| [event.to_s, { from: Array(spec[:from]).map(&:to_s), to: spec[:to].to_s, who: spec.fetch(:who, :writer) }] }
    end

    def transition(event) = transition_table[event.to_s]

    def allows?(event, from_status)
      spec = transition(event)
      spec.present? && spec[:from].include?(from_status.to_s)
    end

    def events_from(status) = transition_table.select { |_, spec| spec[:from].include?(status.to_s) }.keys

    # Adds an error to `record` for each problem with its details document.
    def validate_details(record, details)
      unless details.is_a?(Hash)
        record.errors.add(:details, 'must be a set of named fields')
        return
      end
      unknown = details.keys.map(&:to_s) - fields.keys
      record.errors.add(:details, "has unknown fields: #{unknown.sort.to_sentence}") if unknown.any?
      fields.each { |name, spec| validate_field(record, name, details[name], spec) }
    end

    private

    def validate_field(record, name, value, spec)
      if value.nil? || value == ''
        record.errors.add(:details, "#{name.humanize} is required") if spec[:required]
        return
      end
      ok = case spec[:type]
           when :string, :text then value.is_a?(String) && value.length <= spec.fetch(:max, spec[:type] == :string ? 200 : 10_000)
           when :integer then value.is_a?(Integer)
           when :boolean then [true, false].include?(value)
           when :date then value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/) && Date.iso8601(value)
           when :url then value.is_a?(String) && value.length <= 2000 && value.match?(%r{\Ahttps://[^\s]+\z})
           end
      record.errors.add(:details, "#{name.humanize} is not a valid #{spec[:type]}") unless ok
    rescue Date::Error
      record.errors.add(:details, "#{name.humanize} is not a valid date")
    end
  end
end
