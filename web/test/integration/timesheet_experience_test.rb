# frozen_string_literal: true

require 'test_helper'
require_relative '../acceptance/walkthrough_helper'

# The 2026-11 timesheet review (docs/audits/2026-11-02-timesheets-ux-review.md): the staff week starts from the
# clock, reviewers see clock times and exact totals, pay periods follow Pay rules, and blocked approvals say why.
class TimesheetExperienceTest < ActionDispatch::IntegrationTest
  include WalkthroughHelper

  setup do
    synthetic_workspace('Timesheet experience')
    @owner, = person('exp-owner@example.test', 'admin', 'Ada', 'Owner', rate_cents: 2000)
    @manager, = person('exp-manager@example.test', 'manager', 'Max', 'Manager')
    @staff, @worker = person('exp-sam@example.test', 'employee', 'Sam', 'Staff', rate_cents: 1500)
    Current.reset
  end

  # Pay rules default to weekly Thursday-Wednesday; Thu Oct 22 - Wed Oct 28, 2026 is one pay week.
  def shift!(from, to)
    Current.tenant = @tenant
    ClockShift.create!(user: @staff, employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name,
      employment_type: @worker.employment_type, request_token: SecureRandom.hex(12),
      started_at: Time.zone.parse(from), ended_at: to && Time.zone.parse(to))
  end

  test 'opening the week imports finished clock shifts so staff check rather than type' do
    shift!('2026-10-22 09:00', '2026-10-22 16:30')
    shift!('2026-10-24 22:00', '2026-10-25 02:15')
    at('2026-10-26 12:00') do
      sign_in(@staff)
      get employee_app_path
      assert_select 'h2', 'This pay week'
      assert_includes response.body, 'Oct 22 – 28, 2026'
      assert_select '[data-clocked-hours]', text: /11\.75/
      post employee_week_path
      sheet = People::Timesheet.find_by!(employee: @worker)
      assert_equal [Date.new(2026, 10, 22), Date.new(2026, 10, 28)], [sheet.period_start, sheet.period_end]
      assert_equal BigDecimal('11.75'), sheet.total_hours
      assert_equal 3, sheet.entries.count, 'the overnight shift splits at midnight'
      assert_equal %w[created import_shifts], sheet.events.order(:id).pluck(:action)
      follow_redirect!
      assert_select 'h1', 'Sam Staff'
      assert_select '[data-total-hours]', '11.75'
      assert_includes response.body, '9:00 AM – 4:30 PM'
      assert_includes response.body, '10:00 PM – Oct 25, 2:15 AM'
      assert_select '[data-unimported-shifts]', count: 0
      assert_select 'form[data-turbo-confirm*="Submit 11.75 h"]'
      assert_select '[data-timesheet-status=draft]', 'Draft'
    end
  end

  test 'a draft says when finished shifts are missing and hand entries default to an empty past day' do
    at('2026-10-26 12:00') do
      sign_in(@staff)
      post employee_week_path
      sheet = People::Timesheet.find_by!(employee: @worker)
      shift!('2026-10-22 09:00', '2026-10-22 17:00')
      get people_timesheet_path(sheet)
      assert_select '[data-unimported-shifts]', text: /1 finished clock shift not on this timesheet yet/
      assert_select 'input[name="timesheet_entry[worked_on]"][value="2026-10-22"]'
      post import_shifts_people_timesheet_path(sheet)
      assert_equal 'Clock shifts imported.', flash[:notice]
      get people_timesheet_path(sheet)
      assert_select '[data-unimported-shifts]', count: 0
      assert_select 'input[name="timesheet_entry[worked_on]"][value="2026-10-23"]', 1, 'the clocked day is skipped'
      assert_select 'input[name="timesheet_entry[hours]"]:not([value])'
    end
  end

  test 'reviewers see pay periods, people who worked without a timesheet and blocked corrections' do
    shift!('2026-10-22 09:00', '2026-10-22 17:00')
    at('2026-10-26 12:00') do
      sign_in(@staff)
      post employee_week_path
      sheet = People::Timesheet.find_by!(employee: @worker)
      post '/time_clock/shifts/' + ClockShift.find_by!(employee: @worker).id.to_s + '/correction',
        params: { clock_correction: { proposed_started_at: '2026-10-22T08:30:00', proposed_ended_at: '2026-10-22T17:00:00', reason: 'Opened early' } }
      sign_in(@manager)
      get people_timesheets_path
      assert_select '[data-pay-period="2026-10-22"]', text: /This pay week.*Oct 22 – 28, 2026.*1 draft/m
      assert_select '[data-pay-period="2026-10-15"]', text: /Last pay week/
      assert_select '[data-corrections-waiting]', text: /1 clock correction waiting for review/
      assert_select '[data-corrections-waiting] a[href=?]', time_clock_path(anchor: 'corrections'), text: 'Review corrections'
      get people_timesheet_path(sheet)
      correction = ClockCorrection.find_by!(status: 'pending')
      assert_select '[data-pending-corrections] form[action=?]', approve_correction_time_clock_path(correction, return_to: people_timesheet_path(sheet))
      post approve_correction_time_clock_path(correction, return_to: people_timesheet_path(sheet))
      assert_redirected_to people_timesheet_path(sheet)
      assert correction.reload.status == 'approved'
    end
  end

  test 'a returned week leads with the comment and a reopen action for its owner' do
    shift!('2026-10-22 09:00', '2026-10-22 17:00')
    at('2026-10-26 12:00') do
      sign_in(@staff)
      post employee_week_path
      sheet = People::Timesheet.find_by!(employee: @worker)
      post submit_people_timesheet_path(sheet)
      assert_match(/locked until a reviewer/, flash[:notice])
      sign_in(@manager)
      get people_timesheets_path
      assert_select 'a.btn-primary[href=?]', people_timesheet_path(sheet), text: 'Review'
      post reject_people_timesheet_path(sheet), params: { review_note: '  ' }
      assert sheet.reload.submitted?, 'a blank note cannot return a week'
      assert_match(/Write what needs fixing/, flash[:alert])
      post reject_people_timesheet_path(sheet), params: { review_note: 'Add your Saturday cover.' }
      sign_in(@staff)
      get people_timesheet_path(sheet)
      assert_select '[data-timesheet-status=rejected]', 'Returned'
      assert_select 'section[aria-label="Review comment"]', text: /What to fix.*Add your Saturday cover\./m
      assert_select 'form[action=?] button, form[action=?] input[type=submit]', reopen_people_timesheet_path(sheet), reopen_people_timesheet_path(sheet)
      assert_includes response.body, 'Returned for correction: “Add your Saturday cover.”'
    end
  end

  test 'timesheet reviewers approve clock corrections, never for their own shift; other staff cannot' do
    shift = shift!('2026-10-22 09:00', '2026-10-22 17:00')
    leader = User.create!(tenant: @tenant, email: 'exp-leader@example.test', name: 'Lee Leader', role: 'shift_leader', password: PASSWORD)
    cashier = User.create!(tenant: @tenant, email: 'exp-cashier@example.test', name: 'Cass Cashier', role: 'cashier', password: PASSWORD)
    at('2026-10-26 12:00') do
      sign_in(@staff)
      post "/time_clock/shifts/#{shift.id}/correction", params: { clock_correction: { proposed_started_at: '2026-10-22T08:30:00', proposed_ended_at: '2026-10-22T17:00:00', reason: 'Opened early' } }
      correction = ClockCorrection.find_by!(status: 'pending')

      sign_in(cashier)
      get time_clock_path
      assert_select '#corrections', count: 0
      post approve_correction_time_clock_path(correction)
      assert_equal 'pending', correction.reload.status

      sign_in(leader)
      get time_clock_path
      assert_select "#corrections [data-correction-id='#{correction.id}'] form[action=?]", approve_correction_time_clock_path(correction)
      post approve_correction_time_clock_path(correction)
      assert_equal ['approved', leader.id], [correction.reload.status, correction.reviewed_by_id]
      assert_equal Time.zone.parse('2026-10-22 08:30'), shift.reload.started_at

      # The manager's own shift: they see it waiting but cannot approve it themselves.
      manager_worker = People::Employee.find_by!(user: @manager)
      own = ClockShift.create!(user: @manager, employee: manager_worker, employee_key: manager_worker.id.to_s, employee_name: manager_worker.name,
        employment_type: manager_worker.employment_type, request_token: SecureRandom.hex(12),
        started_at: Time.zone.parse('2026-10-23 09:00'), ended_at: Time.zone.parse('2026-10-23 17:00'))
      sign_in(@manager)
      post "/time_clock/shifts/#{own.id}/correction", params: { clock_correction: { proposed_started_at: '2026-10-23T08:00:00', proposed_ended_at: '2026-10-23T17:00:00', reason: 'Delivery' } }
      mine = ClockCorrection.find_by!(clock_shift: own)
      post approve_correction_time_clock_path(mine)
      assert_equal 'pending', mine.reload.status
      assert_match(/Another reviewer/, flash[:alert])
    end
  end

  test 'correction reviews only return to a timesheet path' do
    shift = shift!('2026-10-22 09:00', '2026-10-22 17:00')
    at('2026-10-26 12:00') do
      sign_in(@staff)
      post "/time_clock/shifts/#{shift.id}/correction", params: { clock_correction: { proposed_started_at: '2026-10-22T08:30:00', proposed_ended_at: '2026-10-22T17:00:00', reason: 'Opened early' } }
      sign_in(@owner)
      correction = ClockCorrection.find_by!(status: 'pending')
      post reject_correction_time_clock_path(correction, return_to: 'https://example.com/elsewhere')
      assert_redirected_to time_clock_path
    end
  end

  test 'staff home puts the clock before lessons on a first visit' do
    sign_in(@staff)
    get employee_app_path
    body = response.body
    assert_operator body.index('Clock in'), :<, body.index('This pay week')
    welcome = body.index('What will you mostly do here?')
    assert_operator body.index('Clock in'), :<, welcome if welcome
  end
end
