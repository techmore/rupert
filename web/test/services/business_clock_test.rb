# frozen_string_literal: true

require 'test_helper'

# BusinessClock replaced ~30 literal 'America/New_York' zones. For the
# single-tenant Eastern case every answer must match the literal it replaced.
class BusinessClockTest < ActiveSupport::TestCase
  EASTERN = ActiveSupport::TimeZone['America/New_York']

  test 'defaults to the configured Eastern zone under its IANA name' do
    assert_equal 'America/New_York', BusinessClock.zone.name
    assert_equal 'America/New_York', BusinessClock.zone_name
    assert_equal EASTERN.tzinfo, BusinessClock.zone.tzinfo
  end

  test 'today is the Eastern date whatever Time.zone the request runs in' do
    travel_to Time.utc(2026, 3, 2, 3, 30) do
      Time.use_zone('UTC') do
        assert_equal Date.new(2026, 3, 1), BusinessClock.today
        assert_equal Time.current.in_time_zone('America/New_York').to_date, BusinessClock.today
        assert_equal Time.find_zone!('America/New_York').today, BusinessClock.today
      end
    end
  end

  test 'day windows match the literal-zone midnight-to-midnight ranges, including DST days' do
    [Date.new(2026, 3, 8), Date.new(2026, 11, 1), Date.new(2026, 7, 4), Date.new(2026, 12, 31)].each do |date|
      expected = EASTERN.local(date.year, date.month, date.day)...EASTERN.local((date + 1).year, (date + 1).month, (date + 1).day)
      assert_equal expected, BusinessClock.day_window(date)
    end
    assert_equal 23.hours, BusinessClock.day_window(Date.new(2026, 3, 8)).then { it.end - it.begin }
    from, to = Date.new(2026, 10, 1), Date.new(2026, 10, 31)
    assert_equal EASTERN.local(2026, 10, 1)...EASTERN.local(2026, 11, 1), BusinessClock.range(from, to)
  end

  test 'use sets Time.zone exactly as Time.use_zone with the literal did' do
    old = Time.use_zone('America/New_York') { [Time.zone.name, Date.current] }
    assert_equal old, BusinessClock.use { [Time.zone.name, Date.current] }
  end

  test 'a location with a valid zone wins; a blank or unknown one falls back' do
    chicago = Location.new(timezone: 'America/Chicago')
    assert_equal 'America/Chicago', BusinessClock.zone_name(location: chicago)
    assert_equal 'America/New_York', BusinessClock.zone_name(location: Location.new(timezone: 'Mars/Olympus'))
    assert_equal 'America/New_York', BusinessClock.zone_name(location: Location.new(timezone: ''))
    assert_equal 'America/New_York', BusinessClock.zone_name(tenant: nil, location: nil)
  end

  test 'date_of reads a Time on the business calendar and leaves a Date alone' do
    assert_equal Date.new(2026, 3, 1), BusinessClock.date_of(Time.utc(2026, 3, 2, 3, 30))
    assert_equal Date.new(2026, 3, 2), BusinessClock.date_of(Date.new(2026, 3, 2))
  end

  test 'callers that stored or requested the zone still say America/New_York' do
    report = MoneyReconciliationReport.new(kind: 'daily', date: Date.new(2026, 10, 1))
    assert_equal EASTERN.local(2026, 10, 1)...EASTERN.local(2026, 10, 2), report.instance_variable_get(:@range)
    assert_equal BusinessClock.day_window(Date.new(2026, 10, 1)), SwipesimpleDayClose.new(Date.new(2026, 10, 1)).window
    assert_equal BusinessClock.today, SwipesimpleWeb::ReportStore.today
  end
end
