# frozen_string_literal: true

# The one answer to "what day is it for this business?". Business days run
# midnight to midnight in the business's time zone: a location's own zone when
# it has a valid one, otherwise the app's configured zone (config.time_zone,
# Eastern Time = America/New_York). No tenant stores its own zone yet; the
# tenant argument is accepted so callers already say whose clock they mean.
#
# Use this instead of a literal 'America/New_York': reports, day closes, jobs
# and source-export requests all read the same zone.
module BusinessClock
  module_function

  # ActiveSupport::TimeZone for the business (or one of its locations).
  def zone(tenant: Current.tenant, location: nil)
    find(location_zone_name(location)) || find(tenant_zone_name(tenant)) || default_zone
  end

  # IANA identifier ("America/New_York") for stored payloads and source requests.
  def zone_name(tenant: Current.tenant, location: nil) = zone(tenant: tenant, location: location).tzinfo.name

  def today(tenant: Current.tenant, location: nil) = zone(tenant: tenant, location: location).today

  def now(tenant: Current.tenant, location: nil) = Time.current.in_time_zone(zone(tenant: tenant, location: location))

  # Midnight-to-midnight business day as a half-open Time range.
  def day_window(date, tenant: Current.tenant, location: nil) = range(date, date, tenant: tenant, location: location)

  # First midnight of +from+ up to (not including) the midnight after +to+.
  def range(from, to, tenant: Current.tenant, location: nil)
    clock = zone(tenant: tenant, location: location)
    first, last = from.to_date, to.to_date + 1
    clock.local(first.year, first.month, first.day)...clock.local(last.year, last.month, last.day)
  end

  # The business date of a Time (a Date stays as it is).
  def date_of(value, tenant: Current.tenant, location: nil)
    return value if value.is_a?(Date) && !value.is_a?(DateTime)

    value.in_time_zone(zone(tenant: tenant, location: location)).to_date
  end

  # Runs the block with Time.zone set to the business zone (jobs, briefs).
  def use(tenant: Current.tenant, location: nil, &)
    Time.use_zone(zone(tenant: tenant, location: location), &)
  end

  # Normalised to its IANA name so zone.name reads "America/New_York", as the
  # literal zones this replaced did, not the Rails alias "Eastern Time (US & Canada)".
  def default_zone = Time.find_zone!(Time.find_zone!(Rails.application.config.time_zone).tzinfo.name)

  def find(name) = name.present? ? Time.find_zone(name.to_s) : nil

  def location_zone_name(location) = location.respond_to?(:timezone) ? location.timezone : nil

  def tenant_zone_name(tenant) = tenant.respond_to?(:time_zone) ? tenant.time_zone : nil
end
