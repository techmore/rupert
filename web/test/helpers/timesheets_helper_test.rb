# frozen_string_literal: true

require 'test_helper'

class TimesheetsHelperTest < ActionView::TestCase
  test 'hours always show two decimals so a total equals the sum of its days' do
    days = [7.5, 7.5, 8.25, 7.5, 7.5].map { |h| BigDecimal(h.to_s) }
    assert_equal '38.25', format_hours(days.sum)
    assert_equal '8.25 h', format_hours(BigDecimal('8.25'), unit: true)
    assert_equal '0.00', format_hours(0)
    assert_equal '–', format_hours(0, blank_zero: true)
    assert_equal '–', format_hours(nil, blank_zero: true)
    assert_equal '1,234.50', format_hours(1234.5)
  end

  test 'periods are written once, with month and year only where they change' do
    assert_equal 'Oct 22 – 28, 2026', period_range(Date.new(2026, 10, 22), Date.new(2026, 10, 28))
    assert_equal 'Oct 29 – Nov 4, 2026', period_range(Date.new(2026, 10, 29), Date.new(2026, 11, 4))
    assert_equal 'Dec 31, 2026 – Jan 6, 2027', period_range(Date.new(2026, 12, 31), Date.new(2027, 1, 6))
    assert_equal 'Oct 22, 2026', period_range(Date.new(2026, 10, 22), Date.new(2026, 10, 22))
  end

  test 'shift spans name the end date when a shift crosses midnight and say when still open' do
    Time.use_zone('Eastern Time (US & Canada)') do
      start = Time.zone.parse('2026-10-22 09:00')
      assert_equal '9:00 AM – 4:30 PM', shift_span(start, Time.zone.parse('2026-10-22 16:30'))
      assert_equal '10:00 PM – Oct 23, 2:00 AM', shift_span(Time.zone.parse('2026-10-22 22:00'), Time.zone.parse('2026-10-23 02:00'))
      assert_equal '9:00 AM – still clocked in', shift_span(start, nil)
      # Across the fall-back change (Nov 1, 2026), times stay in local wall-clock time.
      assert_equal '11:00 PM – Nov 1, 3:00 AM', shift_span(Time.zone.parse('2026-10-31 23:00'), Time.zone.parse('2026-11-01 03:00'))
      assert_equal 'Oct 22, 2026, 9:00 AM', timesheet_time(start)
    end
  end

  test 'one status word and pill per state' do
    { 'draft' => %w[Draft pill-taupe], 'submitted' => ['In review', 'pill-clay'], 'approved' => %w[Approved pill-fern],
      'rejected' => %w[Returned pill-rose] }.each do |status, (label, pill)|
      html = Nokogiri::HTML.fragment(timesheet_status_pill(status))
      assert_equal label, html.text
      assert_equal pill, html.at('span')['class']
      assert_equal label, timesheet_status_label(status)
    end
  end

  test 'history reads as sentences and keeps the review note' do
    event = People::TimesheetEvent.new(action: 'reject', details: { 'review_note' => 'Check Saturday.' })
    assert_equal 'Returned for correction: “Check Saturday.”', timesheet_event_sentence(event)
    assert_equal 'Imported clock shifts', timesheet_event_sentence(People::TimesheetEvent.new(action: 'import_shifts', details: {}))
  end
end
