# frozen_string_literal: true

module Marketing
  # The marketing kinds of the shared work-item table (#407 phase 3, #415; docs/architecture/shared-work-items.md):
  #
  # marketing_event — a dated promotion: an in-store event, a market stall, an online launch or a social post. Its
  #   local start and end (`starts_at`/`ends_at`, wall time in `time_zone`) live in details; start_on/due_on carry
  #   the local dates so the calendar can find it with one indexed range query. A venue (physical place, optionally a
  #   store location) or a channel (where online) says where; `source` is the campaign, `offer_id` the discount code.
  #   Observed redemptions and results are facts, not work: they live in marketing_results (Marketing::Result).
  # campaign_task — a piece of work for a campaign or one of its events (print flyers, book the table). `source` is
  #   the campaign, `parent` the event when there is one.
  #
  # Both are read with marketing.read and changed with marketing.write, only while the workspace has Marketing on
  # (Marketing::WorkItemPolicy). Staff (employee) accounts have no marketing access.
  module WorkKinds
    CHANNELS = {
      'in_store' => 'In store', 'market' => 'Market or fair', 'online' => 'Online store', 'social' => 'Social media',
      'email' => 'Email', 'community' => 'Community group', 'influencer' => 'Influencer', 'other' => 'Other'
    }.freeze
    PERMISSIONS = { read: 'marketing.read', write: 'marketing.write' }.freeze
    POLICY = 'Marketing::WorkItemPolicy'

    module_function

    def event_kind
      Work::Kind.new(
        key: 'marketing_event', label: 'Marketing event', policy: POLICY, activity_prefix: 'marketing_event',
        statuses: %w[planned confirmed held cancelled], initial_status: 'planned', started_statuses: %w[confirmed], done_statuses: %w[held cancelled],
        transitions: {
          'confirm' => { from: %w[planned], to: 'confirmed', who: :writer },
          'hold' => { from: %w[planned confirmed], to: 'held', who: :writer },
          'cancel' => { from: %w[planned confirmed], to: 'cancelled', who: :manager },
          'reopen' => { from: %w[held cancelled], to: 'planned', who: :manager }
        },
        fields: {
          'starts_at' => { type: :datetime, required: true }, 'ends_at' => { type: :datetime, required: true },
          'time_zone' => { type: :string, max: 64, required: true }, 'venue' => { type: :string, max: 200 },
          'channel' => { type: :string, max: 20 }, 'location_id' => { type: :string, max: 100 }, 'offer_id' => { type: :integer },
          'url' => { type: :url }
        },
        permissions: PERMISSIONS,
        path: ->(item) { Rails.application.routes.url_helpers.marketing_event_path(item) },
        calendar: :span,
        prepare: method(:prepare_event),
        check: method(:check_event)
      )
    end

    def campaign_task_kind
      Work::Kind.new(
        key: 'campaign_task', label: 'Campaign task', policy: POLICY, activity_prefix: 'campaign_task',
        statuses: %w[todo in_progress done cancelled], initial_status: 'todo', started_statuses: %w[in_progress], done_statuses: %w[done cancelled],
        transitions: {
          'start' => { from: %w[todo], to: 'in_progress', who: :assignee },
          'finish' => { from: %w[todo in_progress], to: 'done', who: :assignee },
          'cancel' => { from: %w[todo in_progress], to: 'cancelled', who: :manager },
          'reopen' => { from: %w[done cancelled], to: 'todo', who: :manager }
        },
        permissions: PERMISSIONS,
        path: lambda { |item|
          helpers = Rails.application.routes.url_helpers
          item.parent_id ? helpers.marketing_event_path(item.parent_id, anchor: 'event-work') : helpers.marketing_events_path
        },
        calendar: :due,
        check: method(:check_campaign_task)
      )
    end

    # The event's wall times parsed in its own time zone, or nil.
    def zone_for(item)
      name = item.details['time_zone'].to_s
      ActiveSupport::TimeZone[name] if name.present?
    end

    def local_time(item, field)
      zone = zone_for(item)
      value = item.details[field].to_s
      zone.parse(value) if zone && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}\z/)
    rescue ArgumentError
      nil
    end

    def prepare_event(item)
      starts = item.details['starts_at'].to_s
      ends = item.details['ends_at'].to_s
      item.start_on = parse_date(starts)
      item.due_on = parse_date(ends) || item.start_on
    end

    def parse_date(text)
      Date.iso8601(text.first(10)) if text.match?(/\A\d{4}-\d{2}-\d{2}/)
    rescue Date::Error
      nil
    end

    def check_event(item)
      details = item.details
      item.errors.add(:details, 'Time zone is not a known time zone') if details['time_zone'].present? && zone_for(item).nil?
      starts = local_time(item, 'starts_at')
      ends = local_time(item, 'ends_at')
      item.errors.add(:details, 'Ends at must be after the start') if starts && ends && ends <= starts
      item.errors.add(:details, 'Ends at must be within 92 days of the start') if starts && ends && ends > starts + 92.days
      item.errors.add(:details, 'Give a venue or a channel') if details['venue'].blank? && details['channel'].blank?
      item.errors.add(:details, 'Channel is not a known channel') if details['channel'].present? && !CHANNELS.key?(details['channel'])
      tenant_id = item.tenant_id || Current.tenant_id
      if details['location_id'].present? && !Location.unscoped.exists?(tenant_id: tenant_id, externalId: details['location_id'])
        item.errors.add(:details, 'Location was not found in this workspace')
      end
      if details['offer_id'].present? && !Marketing::Offer.unscoped.exists?(tenant_id: tenant_id, id: details['offer_id'])
        item.errors.add(:details, 'Offer was not found in this workspace')
      end
      check_campaign_source(item, tenant_id)
      item.errors.add(:parent, 'is not used for marketing events') if item.parent_id.present?
    end

    def check_campaign_task(item)
      tenant_id = item.tenant_id || Current.tenant_id
      check_campaign_source(item, tenant_id)
      if item.parent_id.present?
        parent = Work::Item.unscoped.find_by(id: item.parent_id, tenant_id: tenant_id)
        item.errors.add(:parent, 'must be a marketing event') unless parent&.kind == 'marketing_event'
      elsif item.source_id.blank?
        item.errors.add(:base, 'A campaign task needs a campaign or an event')
      end
    end

    def check_campaign_source(item, tenant_id)
      return if item.source_type.blank? && item.source_id.blank?

      valid = item.source_type == 'Marketing::Campaign' && Marketing::Campaign.unscoped.exists?(tenant_id: tenant_id, id: item.source_id)
      item.errors.add(:source, 'must be a campaign in this workspace') unless valid
    end
  end
end
