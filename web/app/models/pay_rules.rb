# frozen_string_literal: true

# The workspace's pay rules (#423), stored as one Setting row so a page reads them with one query:
#
# - Pay period: weekly or every two weeks, starting on a chosen weekday. Every-two-weeks periods
#   are counted from an anchor date (the first day of any one period). Until someone chooses,
#   Rupert keeps weekly Thursday-Wednesday and says the period is not chosen.
# - Overtime: off by default. When turned on, hours over the threshold in each seven-day work week
#   are estimated at the multiplier.
# - Admins: a worker whose linked sign-in account is an administrator (admin or platform admin)
#   gets no tip share and no commission. A worker with no linked account is not an admin.
#
# Clock punches are never rounded: hours are the recorded seconds between clock-in and clock-out.
class PayRules
  KEY = 'tenant_pay_rules'
  PERIODS = %w[weekly biweekly].freeze
  PERIOD_LABELS = { 'weekly' => 'Weekly', 'biweekly' => 'Every two weeks' }.freeze
  DAYS = %w[monday tuesday wednesday thursday friday saturday sunday].freeze
  ADMIN_ROLES = %w[admin super_admin].freeze
  DEFAULTS = {
    'pay_period' => 'weekly',
    'week_start_day' => 'thursday',
    'anchor_date' => nil,
    'chosen_at' => nil,
    'chosen_by' => nil,
    'overtime_enabled' => false,
    'overtime_threshold_hours' => 40,
    'overtime_multiplier' => '1.5'
  }.freeze
  MAX_THRESHOLD_HOURS = 168
  MAX_MULTIPLIER = 3

  class Invalid < StandardError; end

  attr_reader :pay_period, :week_start_day, :anchor_date, :chosen_at, :chosen_by,
    :overtime_threshold_hours, :overtime_multiplier

  # One read per request: memoised in Current for the workspace.
  def self.current
    cached = Current.pay_rules
    return cached if cached && cached.tenant_id == Current.tenant_id

    Current.pay_rules = load(Current.tenant_id)
  end

  def self.load(tenant_id)
    raw = Setting.find_by(key: KEY, tenant_id: tenant_id)&.value
    data = raw.present? ? JSON.parse(raw) : {}
    new(DEFAULTS.merge(data.slice(*DEFAULTS.keys)), tenant_id: tenant_id)
  rescue JSON::ParserError
    new(DEFAULTS, tenant_id: tenant_id)
  end

  # Whether the pay period has been chosen (the release gate asks on every page an owner sees; the
  # rules are read once per request).
  def self.pay_period_chosen? = current.chosen?

  # Saves the pay period and overtime rules. Saving the pay period marks it chosen by `actor`.
  def self.save!(attrs, actor:, tenant_id: Current.tenant_id)
    current = load(tenant_id)
    data = current.to_h.merge(attrs.to_h.stringify_keys.slice(*DEFAULTS.keys - %w[chosen_at chosen_by]))
    data['overtime_enabled'] = ActiveModel::Type::Boolean.new.cast(data['overtime_enabled']) || false
    data['anchor_date'] = data['anchor_date'].presence
    if attrs.to_h.stringify_keys.key?('pay_period')
      data['chosen_at'] = Time.current.iso8601
      data['chosen_by'] = actor&.display_name.presence || actor&.email
    end
    rules = new(data, tenant_id: tenant_id)
    rules.validate!
    Setting.find_or_create_for(KEY, tenant_id) { |setting| setting.value = rules.to_h.to_json }
    Current.pay_rules = nil
    rules
  end

  def initialize(data, tenant_id: nil)
    @tenant_id = tenant_id
    @pay_period = data['pay_period'].to_s
    @week_start_day = data['week_start_day'].to_s
    @anchor_date = parse_date(data['anchor_date'])
    @chosen_at = data['chosen_at'].present? ? Time.zone.parse(data['chosen_at'].to_s) : nil
    @chosen_by = data['chosen_by'].presence
    @overtime_enabled = data['overtime_enabled'] == true
    @overtime_threshold_hours = data['overtime_threshold_hours'].to_s.to_d
    @overtime_multiplier = data['overtime_multiplier'].to_s.to_d
  end

  attr_reader :tenant_id

  def validate!
    raise Invalid, 'Choose weekly or every two weeks.' unless PERIODS.include?(pay_period)
    raise Invalid, 'Choose the day the pay week starts.' unless DAYS.include?(week_start_day)
    if biweekly?
      raise Invalid, 'Every two weeks needs the first day of one pay period.' unless anchor_date
      raise Invalid, "The first day of the pay period must be a #{week_start_day.capitalize}." unless anchor_date == week_start(anchor_date)
    end
    raise Invalid, "Overtime starts after 1 to #{MAX_THRESHOLD_HOURS} hours a week." unless overtime_threshold_hours.between?(1, MAX_THRESHOLD_HOURS)
    raise Invalid, "The overtime multiplier must be between 1 and #{MAX_MULTIPLIER}." unless overtime_multiplier.between?(1, MAX_MULTIPLIER)

    self
  end

  def to_h
    { 'pay_period' => pay_period, 'week_start_day' => week_start_day, 'anchor_date' => anchor_date&.iso8601,
      'chosen_at' => chosen_at&.iso8601, 'chosen_by' => chosen_by, 'overtime_enabled' => overtime_enabled?,
      'overtime_threshold_hours' => overtime_threshold_hours.to_s('F').delete_suffix('.0'),
      'overtime_multiplier' => overtime_multiplier.to_s('F') }
  end

  def chosen? = chosen_at.present?
  def biweekly? = pay_period == 'biweekly'
  def overtime_enabled? = @overtime_enabled
  def period_days = biweekly? ? 14 : 7
  def period_label = PERIOD_LABELS.fetch(pay_period, pay_period)
  def start_day_label = week_start_day.capitalize
  def end_day_label = DAYS[(DAYS.index(week_start_day) + 6) % 7].capitalize

  # "Weekly, Thursday to Wednesday" / "Every two weeks, Thursday to Wednesday".
  def summary = "#{period_label}, #{start_day_label} to #{end_day_label}"

  # The first day of the seven-day work week holding `date` (overtime and the schedule's planned
  # hours are counted per work week, whatever the pay period).
  def week_start(date) = date.to_date.beginning_of_week(week_start_day.to_sym)

  # The first day of the pay period holding `date`.
  def period_start(date)
    start = week_start(date)
    return start unless biweekly? && anchor_date

    anchor_date + (((start - anchor_date).to_i / 14) * 14)
  end

  def period_range(date)
    start = period_start(date)
    [start, start + period_days - 1]
  end

  # Employee ids (as ClockShift#employee_key strings) of the workers in `shifts` whose linked
  # sign-in account is an administrator. One query.
  def self.admin_keys(shifts)
    ids = shifts.filter_map(&:employee_id).uniq
    admins = ids.empty? ? [] : People::Employee.where(id: ids).where(user_id: User.where(role: ADMIN_ROLES).select(:id)).pluck(:id)
    shifts.select { |shift| admins.include?(shift.employee_id) }.map(&:employee_key).to_set
  end

  def self.admin_employee?(employee)
    ADMIN_ROLES.include?(employee&.user&.role.to_s)
  end

  private

  def parse_date(value)
    value.present? ? Date.iso8601(value.to_s) : nil
  rescue Date::Error
    nil
  end
end
