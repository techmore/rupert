# frozen_string_literal: true

# Settings → Time rules: labour and tip policy per store (TimeRules). The workspace default applies
# everywhere; a store override changes only the fields that differ. Saved by whoever may save
# settings (the same people who choose the pay rules).
class TimeRulesSettingsController < AuthenticatedController
  before_action { authorize(:module, :settings_read?) }

  SECTIONS = { 'rules' => TimeRules::RULE_KEYS, 'features' => TimeRules::FEATURES.keys,
               'logging' => TimeRules::LOGGING.keys + %w[punch_audit_retention_years] }.freeze
  NOTICES = { 'rules' => 'Time rules saved for %s.', 'features' => 'Saved what is turned on for %s.', 'logging' => 'Punch logging saved for %s.' }.freeze

  def show
    load_rules
  end

  # One form per section: `rules` (per store), `features` and `logging` (workspace-wide). An unchecked
  # box is not posted, so only the posted section's checkboxes are read as "off".
  def update
    authorize(:module, :time_rules_write?)
    load_rules
    section = SECTIONS.key?(params[:section].to_s) ? params[:section].to_s : 'rules'
    return redirect_to(time_rules_settings_path, alert: 'These switches apply to the whole workspace. Choose “Every store” first.') if section != 'rules' && @location

    keys = SECTIONS.fetch(section)
    attrs = params.fetch(:time_rules, {}).permit(*keys).to_h
    (TimeRules::BOOLEAN_KEYS & keys).each { |key| attrs[key] = attrs.key?(key) ? attrs[key] : '0' } if attrs.any? || section != 'rules'
    TimeRules.save!(attrs, location_id: @location&.id, actor: Current.user)
    save_time_zone if section == 'rules' && @location.nil? && params.key?(:workspace_time_zone)
    redirect_to time_rules_settings_path(location_id: @location&.id, anchor: (section unless section == 'rules')),
      notice: format(NOTICES.fetch(section), @location ? @location.name : 'every store')
  rescue TimeRules::Invalid, ActiveRecord::RecordInvalid => e
    redirect_to time_rules_settings_path(location_id: @location&.id), alert: e.is_a?(ActiveRecord::RecordInvalid) ? e.record.errors.full_messages.to_sentence : e.message
  end

  private

  def load_rules
    @locations = Location.for_shifts.order(:name).to_a
    @location = params[:location_id].present? ? @locations.find { |l| l.id == params[:location_id] } : nil
    @rules = TimeRules.for(@location)
    @default_rules = TimeRules.for(nil)
    @can_write = ModulePolicy.new(Current.user, :module).time_rules_write?
    @overrides = @location ? (TimeRules.stored['locations'][@location.id.to_s] || {}).keys : []
    @time_zone = BusinessClock.zone
  end

  # The workspace's clock: which midnight ends a day, a week and a pay period. Blank keeps the
  # instance default. Recorded in the activity log like every other rule.
  def save_time_zone
    tenant = Current.tenant
    chosen = params[:workspace_time_zone].to_s.strip.presence
    return if tenant.time_zone.to_s == chosen.to_s

    was = tenant.time_zone
    tenant.update!(time_zone: chosen)
    ActivityLogger.log('time_rules.updated', subject: nil, label: 'Every store',
      details: { changed: ['time_zone'], changes: { 'time_zone' => [was, chosen] } }.to_json)
  end
end
