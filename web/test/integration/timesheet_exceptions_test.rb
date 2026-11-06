# frozen_string_literal: true

require 'test_helper'
require_relative '../support/time_and_pay_helper'

# Exceptions first on the timesheets list: missed punches, corrections, overtime, missed meals and
# shifts not imported lead the page; bulk approve skips any sheet whose person has a blocking one.
class TimesheetExceptionsTest < ActionDispatch::IntegrationTest
  include TimeAndPayHelper

  setup { time_and_pay_workspace }
  teardown { Current.reset }

  test 'the list leads with exceptions and the one fix for each' do
    travel_to Time.zone.parse('2026-11-04 12:00') do
      # Missed punch: open since two days ago. Long day with no meal. Pending correction. Draft with unimported shifts.
      tp_shift!(@worker, '2026-11-02 09:00')
      _, casey = tp_person('Casey', 'Clerk')
      long = tp_shift!(casey, '2026-10-30 08:00', '2026-10-30 18:00')
      long.corrections.create!(requested_by_id: casey.user_id, original_started_at: long.started_at, original_ended_at: long.ended_at,
        proposed_started_at: long.started_at, proposed_ended_at: long.ended_at - 1.hour, reason: 'Left an hour early')
      casey.timesheets.create!(period_start: '2026-10-29', period_end: '2026-11-04')
      tp_sign_in(@manager)
      get people_timesheets_path
      assert_response :success
      assert_select '[data-needs-attention] [data-exception="missed_punch"]', text: /Never clocked out.*Sam Staff/m
      assert_select '[data-needs-attention] [data-exception="missed_punch"] a', text: 'Fix clock-out'
      assert_select '[data-needs-attention] [data-exception="correction"] button', text: 'Approve'
      assert_select '[data-needs-attention] [data-exception="missed_meal"]', text: /No meal break.*Casey Clerk.*1 long day with no meal recorded \(Fri 30\)/m
      assert_select '[data-needs-attention] [data-exception="unimported"] button', text: 'Import clock shifts'
    end
  end

  test 'bulk approve skips sheets whose person still has a blocking exception and the bar counts' do
    travel_to Time.zone.parse('2026-11-05 12:00') do
      _, casey = tp_person('Casey', 'Clerk')
      clean = tp_submitted_sheet!(casey, '2026-10-29', { '2026-10-30' => 8 })
      tp_shift!(@worker, '2026-11-02 09:00') # Sam never clocked out
      blocked = tp_submitted_sheet!(@worker, '2026-10-29', { '2026-10-30' => 8 })
      tp_sign_in(@manager)
      get people_timesheets_path
      assert_select '.bulk-bar', text: /Select all clean \(1\).*1 need attention first/m
      assert_select "input.bulk-box[value='#{clean.id}']"
      assert_select "input.bulk-box[value='#{blocked.id}']", count: 0
      post bulk_approve_people_timesheets_path, params: { timesheet_ids: [clean.id, blocked.id] }
      assert clean.reload.approved?
      assert blocked.reload.submitted?
      assert_match(/needs attention first/, flash[:alert])
    end
  end

  test 'the timesheet history merges workflow events and punch corrections with originals kept' do
    travel_to Time.zone.parse('2026-11-05 12:00') do
      shift = tp_shift!(@worker, '2026-10-30 09:00', '2026-10-30 17:00')
      sheet = tp_submitted_sheet!(@worker, '2026-10-29', { '2026-10-30' => 8 })
      correction = shift.corrections.create!(requested_by_id: @worker_user.id, original_started_at: shift.started_at, original_ended_at: shift.ended_at,
        proposed_started_at: shift.started_at - 30.minutes, proposed_ended_at: shift.ended_at, reason: 'Opened early')
      Current.user = @manager
      TimeClockService.review(correction: correction, reviewer: @manager, approve: true)
      tp_sign_in(@manager)
      get people_timesheet_path(sheet)
      assert_response :success
      assert_select '[data-audit-trail] li[data-audit-kind="correction"]', minimum: 2
      assert_select '[data-audit-trail]', text: /Asked to fix the punch on Fri Oct 30.*Opened early.*Approved the punch fix.*original 9:00 AM – 5:00 PM kept on record/m
    end
  end

  test 'a manager limited to one store sees only that store’s staff' do
    store_a = Location.create!(name: 'Store A', source: 'rupert', externalId: 'a', active: true)
    store_b = Location.create!(name: 'Store B', source: 'rupert', externalId: 'b', active: true)
    _, bea = tp_person('Bea', 'B', location_ids: [store_b.id])
    @worker.update!(location_ids: [store_a.id])
    sheet_a = tp_submitted_sheet!(@worker, '2026-10-29', { '2026-10-30' => 8 })
    sheet_b = tp_submitted_sheet!(bea, '2026-10-29', { '2026-10-30' => 8 })
    @manager.update!(location_ids: [store_a.id])
    tp_sign_in(@manager)
    get people_timesheets_path
    assert_select 'a[href=?]', people_timesheet_path(sheet_a)
    assert_select 'a[href=?]', people_timesheet_path(sheet_b), count: 0
    post bulk_approve_people_timesheets_path, params: { timesheet_ids: [sheet_b.id] }
    assert sheet_b.reload.submitted?
  end
end
