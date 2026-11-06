# frozen_string_literal: true

require 'test_helper'
require_relative '../support/time_and_pay_helper'

# One inbox for everything waiting on a manager, decided inline; nobody decides their own item.
class ApprovalsInboxTest < ActionDispatch::IntegrationTest
  include TimeAndPayHelper

  setup { time_and_pay_workspace }
  teardown { Current.reset }

  test 'lists corrections, time off and timesheets and decides them inline with a note and a notification' do
    travel_to Time.zone.parse('2026-11-05 12:00') do
      shift = tp_shift!(@worker, '2026-10-30 09:00', '2026-10-30 17:00')
      correction = shift.corrections.create!(requested_by_id: @worker_user.id, original_started_at: shift.started_at, original_ended_at: shift.ended_at,
        proposed_started_at: shift.started_at, proposed_ended_at: shift.ended_at + 1.hour, reason: 'Stayed to close')
      leave = @worker.leave_requests.create!(leave_type: 'vacation', starts_on: '2026-11-20', ends_on: '2026-11-21', hours: 16)
      sheet = tp_submitted_sheet!(@worker, '2026-10-29', { '2026-10-30' => 8 })
      tp_sign_in(@manager)
      get people_approvals_path
      assert_response :success
      assert_select '[data-approvals-count="3"]'
      assert_select '#approval-correction-' + correction.id.to_s, text: /Fix a punch.*Sam Staff.*Stayed to close.*5:00 PM – 6:00 PM|Hours 8\.00 → 9\.00/m
      assert_select '#approval-leave-' + leave.id.to_s, text: /Time off.*Vacation.*16 h.*Less than 7 days notice|Vacation/m
      assert_select '#approval-timesheet-' + sheet.id.to_s, text: /Timesheet.*8\.00 h/m

      post people_approval_decision_path(kind: 'correction', id: correction.id, decision: 'approve'), params: { note: 'Thanks' }, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      assert_response :success
      assert_match(/turbo-stream action="remove" target="approval-correction-#{correction.id}"/, response.body)
      assert_match(/data-approvals-count="2"/, response.body)
      assert_equal 'approved', correction.reload.status
      assert_equal shift.ended_at + 1.hour, shift.reload.ended_at
      assert_equal 'Thanks', correction.review_note

      post people_approval_decision_path(kind: 'leave', id: leave.id, decision: 'deny'), params: { note: 'Inventory week' }
      assert_redirected_to people_approvals_path
      assert leave.reload.denied?
      assert_equal 'Inventory week', leave.review_note
      assert Notification.where(user_id: @worker_user.id, kind: 'approvals').exists?(title: 'Time off Nov 20 – Nov 21: denied')

      post people_approval_decision_path(kind: 'timesheet', id: sheet.id, decision: 'deny')
      assert_match(/Say what to fix/, flash[:alert])
      post people_approval_decision_path(kind: 'timesheet', id: sheet.id, decision: 'approve')
      assert sheet.reload.approved?
      get people_approvals_path
      assert_select '[data-approvals-count="0"]'
      assert_select '.empty-state', text: /Nothing waiting/
    end
  end

  test 'a reviewer never sees their own request and a scoped manager sees only their store' do
    store_a = Location.create!(name: 'Store A', source: 'rupert', externalId: 'a', active: true)
    store_b = Location.create!(name: 'Store B', source: 'rupert', externalId: 'b', active: true)
    _, own = tp_person('Mia', 'Manager2', location_ids: [store_a.id])
    own.update!(user: @manager)
    own_leave = own.leave_requests.create!(leave_type: 'sick', starts_on: '2026-11-20', ends_on: '2026-11-20', hours: 8)
    _, bea = tp_person('Bea', 'B', location_ids: [store_b.id])
    other_leave = bea.leave_requests.create!(leave_type: 'sick', starts_on: '2026-11-20', ends_on: '2026-11-20', hours: 8)
    @worker.update!(location_ids: [store_a.id])
    mine = @worker.leave_requests.create!(leave_type: 'sick', starts_on: '2026-11-21', ends_on: '2026-11-21', hours: 8)
    @manager.update!(location_ids: [store_a.id])
    tp_sign_in(@manager)
    get people_approvals_path
    assert_select "#approval-leave-#{mine.id}"
    assert_select "#approval-leave-#{own_leave.id}", count: 0
    assert_select "#approval-leave-#{other_leave.id}", count: 0
    post people_approval_decision_path(kind: 'leave', id: other_leave.id, decision: 'approve')
    assert_response :not_found
    assert other_leave.reload.requested?
  end

  test 'shift trades appear when the trade workflow is present and are reviewed through it' do
    shift = People::ScheduledShift.create!(employee: @worker, starts_at: 3.days.from_now.change(hour: 9), ends_at: 3.days.from_now.change(hour: 17))
    _, casey = tp_person('Casey', 'Clerk')
    trade = People::ShiftTrade.create!(scheduled_shift: shift, kind: 'give', from_employee: @worker, to_employee: casey, status: 'accepted',
      requested_by: @worker_user, accepted_at: Time.current, checks_json: [{ 'level' => 'warn', 'code' => 'rest', 'message' => 'Short rest before' }].to_json)
    stub = Module.new
    stub.define_singleton_method(:review) { |t, reviewer:, approve:, note: nil| t.update!(status: approve ? 'approved' : 'denied', reviewed_by: reviewer, reviewed_at: Time.current, review_note: note) }
    People.const_set(:ShiftTradeWorkflow, stub) unless People.const_defined?(:ShiftTradeWorkflow, false)
    tp_sign_in(@manager)
    get people_approvals_path(kind: 'trade')
    assert_select "#approval-trade-#{trade.id}", text: /Give away.*Sam Staff → Casey Clerk.*Short rest before/m
    post people_approval_decision_path(kind: 'trade', id: trade.id, decision: 'approve'), params: { note: 'Fine' }
    assert_equal 'approved', trade.reload.status
    assert_equal 'Fine', trade.review_note
  ensure
    People.send(:remove_const, :ShiftTradeWorkflow) if stub && People.const_defined?(:ShiftTradeWorkflow, false) && People::ShiftTradeWorkflow.equal?(stub)
  end

  test 'the inbox is in the rail for reviewers and refused to plain staff' do
    tp_sign_in(@manager)
    get people_timesheets_path
    assert_select 'nav[aria-label="Module"] a[href=?]', people_approvals_path, text: 'Approvals'
    tp_sign_in(@worker_user)
    get people_approvals_path
    assert_response :redirect
  end
end
