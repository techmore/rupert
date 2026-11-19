# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/time_and_pay_helper'

class People::OffboardingTest < ActionDispatch::IntegrationTest
  include TimeAndPayHelper

  setup { time_and_pay_workspace }
  teardown { Current.reset }

  test 'terminating revokes access, clears the PIN, opens future shifts, cancels trades and leaves the open punch for review' do
    @worker.update!(email: @worker_user.email)
    @worker.set_pin!('2580')
    session, _secret = EmployeeAppSession.issue!(user: @worker_user, device_name: 'Phone')
    grant_secret = EmployeeAccessGrant.issue!(@worker)
    future = People::ScheduledShift.create!(employee: @worker, starts_at: 3.days.from_now.change(hour: 9), ends_at: 3.days.from_now.change(hour: 17))
    past = People::ScheduledShift.create!(employee: @worker, starts_at: 3.days.ago.change(hour: 9), ends_at: 3.days.ago.change(hour: 17))
    _, casey = tp_person('Casey', 'Clerk')
    trade = People::ShiftTrade.create!(scheduled_shift: future, kind: 'give', from_employee: @worker, to_employee: casey, status: 'accepted', requested_by: @worker_user)
    open_punch = tp_shift!(@worker, 2.hours.ago.iso8601)
    tp_sign_in(@admin)
    post transition_people_employee_path(@worker, event: 'terminate')
    assert_redirected_to people_employee_path(@worker)
    assert_match(/Access revoked, PIN cleared, 1 future shift opened. An open punch is waiting/, flash[:notice])
    @worker.reload
    assert @worker.terminated?
    assert_not @worker.pin_set?
    assert session.reload.revoked_at.present?
    assert_not EmployeeAccessGrant.lookup(grant_secret).usable?
    assert_nil future.reload.employee_id
    assert_match(/Opened when Sam Staff left/, future.notes)
    assert_equal @worker.id, past.reload.employee_id, 'past shifts stay on the record'
    assert_equal 'cancelled', trade.reload.status
    assert_nil open_punch.reload.ended_at, 'an open punch is never closed silently'
  end
end
