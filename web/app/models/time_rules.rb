# frozen_string_literal: true

# Labour and tip policy per store (docs/time-and-pay/DECISIONS.md). One Setting row holds a default
# block and per-location overrides; `TimeRules.for(location)` merges them. PayRules keeps the owner's
# pay period and weekly overtime switch; TimeRules adds everything a location can differ on: breaks,
# daily overtime, minors, predictive scheduling, rounding, buddy-punch policy, trades, accrual, tips.
#
# Presets are starting points from public federal/state rules as of 2026; they are defaults to be
# confirmed by the owner, never legal advice.
class TimeRules
  KEY = 'tenant_time_rules'

  DEFAULTS = {
    'preset' => 'federal',
    # Breaks: federal law requires none; the defaults remind staff of a common 30/6 meal practice.
    'meal_break_after_hours' => '6',
    'meal_break_minutes' => 30,
    'meal_break_paid' => false,
    'rest_break_every_hours' => '4',
    'rest_break_minutes' => 10,
    'rest_break_paid' => true,
    'break_reminders' => true,
    # Daily overtime is a state rule (CA, AK, NV, CO); weekly overtime lives in PayRules.
    'daily_overtime_threshold_hours' => nil,
    'daily_overtime_multiplier' => '1.5',
    # Minors (under 18). FLSA for under-16s: 7 AM to 7 PM (9 PM June 1 to Labor Day), 3 h school day, 8 h non-school day, 18 h school week, 40 h otherwise.
    'minor_age' => 18,
    'minor_max_daily_hours' => '8',
    'minor_max_weekly_hours' => '40',
    'minor_earliest_start' => '07:00',
    'minor_latest_end' => '19:00',
    # Predictive scheduling: days of notice before a week starts; 0 turns the warning off.
    'schedule_notice_days' => 14,
    'min_rest_between_shifts_hours' => '10',
    # Punch rounding: none (owner decision 2026-10-25). 0, 5, 6 or 15 minutes nearest.
    'rounding_minutes' => 0,
    'grace_minutes' => 0,
    # Buddy-punch prevention: a PIN punch must come from a registered store device or a signed-in session.
    'pin_requires_trusted_device' => true,
    'pin_length' => 4,
    'pin_lockout_attempts' => 5,
    'pin_lockout_minutes' => 10,
    # Trades and pickups.
    'trade_requires_approval' => true,
    'trade_min_notice_hours' => '2',
    'trade_block_overtime' => true,
    'open_shift_requires_position' => false,
    # Time off: paid sick accrues per hour worked (1 per 30 is the common state formula); vacation is an annual grant.
    'sick_accrual_hours_per_hour_worked' => '0',
    'sick_accrual_cap_hours' => '40',
    'vacation_annual_hours' => '80',
    'sick_annual_hours' => '40',
    'carryover_max_hours' => '40',
    'time_off_min_notice_days' => 7,
    # Tips (owner decision 2026-10-25): shared evenly among everyone clocked in when the tip was left, administrators excluded.
    'tip_method' => 'pool',
    'tip_pool_excludes_admins' => true,
    'tip_pool_by_location' => true,
    'cash_tips_declared' => true,
    # Payday: days after the pay period ends (the employee Pay page shows "Next payday").
    'payday_days_after_period_end' => 5
  }.freeze

  PRESETS = {
    'federal' => {},
    'connecticut' => { 'meal_break_after_hours' => '7.5', 'meal_break_minutes' => 30, 'sick_accrual_hours_per_hour_worked' => '0.025', 'sick_accrual_cap_hours' => '40' },
    'massachusetts' => { 'meal_break_after_hours' => '6', 'meal_break_minutes' => 30, 'sick_accrual_hours_per_hour_worked' => '0.0333', 'sick_accrual_cap_hours' => '40' },
    'new_york' => { 'meal_break_after_hours' => '6', 'meal_break_minutes' => 30, 'sick_accrual_hours_per_hour_worked' => '0.0333', 'sick_accrual_cap_hours' => '56', 'schedule_notice_days' => 14 },
    'new_jersey' => { 'sick_accrual_hours_per_hour_worked' => '0.0333', 'sick_accrual_cap_hours' => '40' },
    'california' => { 'meal_break_after_hours' => '5', 'meal_break_minutes' => 30, 'rest_break_every_hours' => '4', 'daily_overtime_threshold_hours' => '8', 'sick_accrual_hours_per_hour_worked' => '0.0333', 'sick_accrual_cap_hours' => '80', 'rounding_minutes' => 0 },
    'oregon' => { 'meal_break_after_hours' => '6', 'rest_break_every_hours' => '4', 'schedule_notice_days' => 14, 'sick_accrual_hours_per_hour_worked' => '0.0333' },
    'colorado' => { 'meal_break_after_hours' => '5', 'rest_break_every_hours' => '4', 'daily_overtime_threshold_hours' => '12', 'sick_accrual_hours_per_hour_worked' => '0.0333', 'sick_accrual_cap_hours' => '48' }
  }.freeze
  PRESET_LABELS = { 'federal' => 'Federal (FLSA) only', 'connecticut' => 'Connecticut', 'massachusetts' => 'Massachusetts', 'new_york' => 'New York',
                    'new_jersey' => 'New Jersey', 'california' => 'California', 'oregon' => 'Oregon', 'colorado' => 'Colorado' }.freeze
  TIP_METHODS = { 'pool' => 'Shared evenly among everyone clocked in', 'direct' => 'Kept by the cashier who rang the sale' }.freeze
  ROUNDING_CHOICES = [0, 5, 6, 15].freeze
  DECIMAL_KEYS = %w[meal_break_after_hours rest_break_every_hours daily_overtime_threshold_hours daily_overtime_multiplier minor_max_daily_hours
                    minor_max_weekly_hours min_rest_between_shifts_hours trade_min_notice_hours sick_accrual_hours_per_hour_worked
                    sick_accrual_cap_hours vacation_annual_hours sick_annual_hours carryover_max_hours].freeze
  INTEGER_KEYS = %w[meal_break_minutes rest_break_minutes minor_age schedule_notice_days rounding_minutes grace_minutes pin_length payday_days_after_period_end
                    pin_lockout_attempts pin_lockout_minutes time_off_min_notice_days].freeze
  BOOLEAN_KEYS = %w[meal_break_paid rest_break_paid break_reminders pin_requires_trusted_device trade_requires_approval trade_block_overtime
                    open_shift_requires_position tip_pool_excludes_admins tip_pool_by_location cash_tips_declared].freeze

  class Invalid < StandardError; end

  attr_reader :data, :location_id

  # Rules for one store (or the workspace default when `location` is nil). One Setting read per request.
  def self.for(location = nil)
    location_id = location.respond_to?(:id) ? location.id : location
    store = stored
    merged = DEFAULTS.merge(PRESETS.fetch(store['default']['preset'].to_s, {})).merge(store['default'])
    merged = merged.merge(store['locations'][location_id.to_s] || {}) if location_id.present?
    new(merged, location_id: location_id)
  end

  def self.stored(tenant_id = Current.tenant_id)
    cache = Current.metadata ||= {}
    key = "time_rules:#{tenant_id}"
    return cache[key] if cache[key]

    raw = Setting.for_tenant(KEY, tenant_id)&.value
    parsed = raw.present? ? JSON.parse(raw) : {}
    cache[key] = { 'default' => (parsed['default'] || {}).slice(*DEFAULTS.keys), 'locations' => (parsed['locations'] || {}).transform_values { |v| v.to_h.slice(*DEFAULTS.keys) } }
  rescue JSON::ParserError
    cache[key] = { 'default' => {}, 'locations' => {} }
  end

  # Saves rules for the default block (location_id nil) or one store's overrides. Only keys that are
  # given change; a store override equal to the default is dropped so the default keeps applying.
  def self.save!(attrs, location_id: nil, actor: Current.user, tenant_id: Current.tenant_id)
    store = stored(tenant_id).deep_dup
    cleaned = coerce(attrs.to_h.stringify_keys.slice(*DEFAULTS.keys))
    if location_id.present?
      base = DEFAULTS.merge(PRESETS.fetch((store['default']['preset'] || 'federal').to_s, {})).merge(store['default'])
      overrides = (store['locations'][location_id.to_s] || {}).merge(cleaned).reject { |k, v| base[k] == v }
      store['locations'][location_id.to_s] = overrides
    else
      store['default'] = store['default'].merge(cleaned)
    end
    merged = DEFAULTS.merge(PRESETS.fetch((store['default']['preset'] || 'federal').to_s, {})).merge(store['default'])
    merged = merged.merge(store['locations'][location_id.to_s] || {}) if location_id.present?
    new(merged, location_id: location_id).validate!
    Setting.find_or_create_for(KEY, tenant_id) { |setting| setting.value = store.to_json }
    (Current.metadata ||= {}).delete("time_rules:#{tenant_id}")
    ActivityLogger.log('time_rules.updated', subject: nil, details: { location_id: location_id, changed: cleaned.keys }.to_json, actor: actor) if defined?(ActivityLogger)
    self.for(location_id)
  end

  def self.coerce(attrs)
    attrs.each_with_object({}) do |(key, value), out|
      out[key] = if BOOLEAN_KEYS.include?(key) then ActiveModel::Type::Boolean.new.cast(value) || false
      elsif INTEGER_KEYS.include?(key) then Integer(value.to_s, exception: false) || DEFAULTS[key]
      elsif DECIMAL_KEYS.include?(key) then value.to_s.strip.presence && BigDecimal(value.to_s, exception: false)&.to_s('F')
      else value.to_s.strip.presence
                 end
    end
  end

  def initialize(data, location_id: nil)
    @data = data
    @location_id = location_id
  end

  def validate!
    raise Invalid, 'Choose a known rule preset.' unless PRESETS.key?(preset)
    raise Invalid, 'Rounding must be none, 5, 6 or 15 minutes.' unless ROUNDING_CHOICES.include?(rounding_minutes)
    raise Invalid, 'A PIN is 4 to 6 digits.' unless (4..6).cover?(pin_length)
    raise Invalid, 'Choose how tips are shared.' unless TIP_METHODS.key?(tip_method)
    raise Invalid, 'Minor age must be 14 to 21.' unless (14..21).cover?(minor_age)
    raise Invalid, 'Schedule notice is 0 to 30 days.' unless (0..30).cover?(schedule_notice_days)
    self
  end

  def preset = data['preset'].to_s
  def preset_label = PRESET_LABELS.fetch(preset, preset)
  def to_h = data

  def decimal(key)
    value = data[key]
    value.nil? || value.to_s.empty? ? nil : BigDecimal(value.to_s)
  end

  def integer(key) = Integer(data[key].to_s, exception: false) || DEFAULTS[key].to_i
  def bool(key) = data[key] == true

  # Breaks
  def meal_break_after_hours = decimal('meal_break_after_hours')
  def meal_break_minutes = integer('meal_break_minutes')
  def meal_break_paid? = bool('meal_break_paid')
  def rest_break_every_hours = decimal('rest_break_every_hours')
  def rest_break_minutes = integer('rest_break_minutes')
  def rest_break_paid? = bool('rest_break_paid')
  def break_reminders? = bool('break_reminders')
  def break_paid?(kind) = kind.to_s == 'meal' ? meal_break_paid? : rest_break_paid?

  # Overtime (daily; weekly is PayRules)
  def daily_overtime_threshold_hours = decimal('daily_overtime_threshold_hours')
  def daily_overtime_multiplier = decimal('daily_overtime_multiplier') || BigDecimal('1.5')
  def daily_overtime? = daily_overtime_threshold_hours.present? && daily_overtime_threshold_hours.positive?

  # Minors
  def minor_age = integer('minor_age')
  def minor_max_daily_hours = decimal('minor_max_daily_hours')
  def minor_max_weekly_hours = decimal('minor_max_weekly_hours')
  def minor_earliest_start = data['minor_earliest_start'].to_s.presence || '07:00'
  def minor_latest_end = data['minor_latest_end'].to_s.presence || '19:00'

  # Scheduling
  def schedule_notice_days = integer('schedule_notice_days')
  def min_rest_between_shifts_hours = decimal('min_rest_between_shifts_hours') || BigDecimal('10')

  # Punches
  def rounding_minutes = integer('rounding_minutes')
  def grace_minutes = integer('grace_minutes')
  def pin_requires_trusted_device? = bool('pin_requires_trusted_device')
  def pin_length = integer('pin_length')
  def pin_lockout_attempts = integer('pin_lockout_attempts')
  def pin_lockout_minutes = integer('pin_lockout_minutes')

  # Rounds a punch time to the nearest rounding interval (no-op when rounding is off).
  def round_punch(time)
    return time if rounding_minutes.zero? || time.nil?

    step = rounding_minutes * 60
    Time.zone.at(((time.to_f + (step / 2.0)).floor / step) * step)
  end

  # Trades
  def trade_requires_approval? = bool('trade_requires_approval')
  def trade_min_notice_hours = decimal('trade_min_notice_hours') || BigDecimal('0')
  def trade_block_overtime? = bool('trade_block_overtime')
  def open_shift_requires_position? = bool('open_shift_requires_position')

  # Time off
  def sick_accrual_hours_per_hour_worked = decimal('sick_accrual_hours_per_hour_worked') || BigDecimal('0')
  def sick_accrual_cap_hours = decimal('sick_accrual_cap_hours')
  def vacation_annual_hours = decimal('vacation_annual_hours') || BigDecimal('0')
  def sick_annual_hours = decimal('sick_annual_hours') || BigDecimal('0')
  def carryover_max_hours = decimal('carryover_max_hours')
  def time_off_min_notice_days = integer('time_off_min_notice_days')
  def sick_accrues? = sick_accrual_hours_per_hour_worked.positive?

  # Tips
  def tip_method = data['tip_method'].to_s
  def tip_method_label = TIP_METHODS.fetch(tip_method, tip_method)
  def tip_pool? = tip_method == 'pool'
  def tip_pool_excludes_admins? = bool('tip_pool_excludes_admins')
  def tip_pool_by_location? = bool('tip_pool_by_location')
  def cash_tips_declared? = bool('cash_tips_declared')
  def payday_days_after_period_end = integer('payday_days_after_period_end')
end
