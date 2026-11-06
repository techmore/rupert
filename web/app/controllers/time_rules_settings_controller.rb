# frozen_string_literal: true

# Settings → Time rules: labour and tip policy per store (TimeRules). The workspace default applies
# everywhere; a store override changes only the fields that differ. Saved by whoever may save
# settings (the same people who choose the pay rules).
class TimeRulesSettingsController < AuthenticatedController
  before_action { authorize(:module, :settings_read?) }

  def show
    load_rules
  end

  def update
    authorize(:module, :time_rules_write?)
    load_rules
    attrs = params.fetch(:time_rules, {}).permit(*TimeRules::DEFAULTS.keys).to_h
    TimeRules::BOOLEAN_KEYS.each { |key| attrs[key] = attrs.key?(key) ? attrs[key] : '0' } if attrs.any?
    TimeRules.save!(attrs, location_id: @location&.id, actor: Current.user)
    redirect_to time_rules_settings_path(location_id: @location&.id), notice: "Time rules saved for #{@location ? @location.name : 'every store'}."
  rescue TimeRules::Invalid => e
    redirect_to time_rules_settings_path(location_id: @location&.id), alert: e.message
  end

  private

  def load_rules
    @locations = Location.for_shifts.order(:name).to_a
    @location = params[:location_id].present? ? @locations.find { |l| l.id == params[:location_id] } : nil
    @rules = TimeRules.for(@location)
    @default_rules = TimeRules.for(nil)
    @can_write = ModulePolicy.new(Current.user, :module).time_rules_write?
    @overrides = @location ? (TimeRules.stored['locations'][@location.id.to_s] || {}).keys : []
  end
end
