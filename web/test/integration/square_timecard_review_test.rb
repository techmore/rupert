# frozen_string_literal: true

require 'test_helper'

class SquareTimecardReviewTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    Current.user = users(:regular_user)
    @admin = Current.user
    @staff = User.create!(tenant: @tenant, email: 'square-review-page-staff@example.invalid', password: 'password123', role: 'employee')
    @worker = People::Employee.create!(first_name: 'Justin', last_name: 'Changed', user: @staff)
    EmployeeSourceIdentity.create!(employee: @worker, source: 'square', external_id: 'review-team')
    SquareTimecardImport.new(rows: [source]).call(apply: true)
    SquareTimecardImport.new(rows: [source(end_at: '2026-10-05T19:30:00-04:00', version: 2)]).call(apply: true)
    @card = SquareTimecard.first
  end
  teardown { Current.reset }

  def source(**attributes)
    { 'id' => 'review-card', 'team_member_id' => 'review-team', 'location_id' => 'native-location', 'timezone' => 'America/New_York',
      'start_at' => '2026-10-05T09:00:00-04:00', 'end_at' => '2026-10-05T17:00:00-04:00', 'status' => 'CLOSED', 'version' => 1,
      'wage' => { 'hourly_rate' => { 'amount' => 2000, 'currency' => 'USD' } } }.merge(attributes.stringify_keys)
  end

  test 'a manager sees counted and latest hours side by side, accepts, and the history keeps both' do
    post login_path, params: { email: @admin.email, password: 'password' }
    get people_square_timesheets_path
    assert_select 'a.btn-primary[href=?]', people_square_timecard_reviews_path, text: 'Review changes (1)'

    get people_square_timecard_reviews_path
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_select 'h1', 'Square changes'
    assert_select 'h2', 'Justin Changed'
    assert_select 'h3', /Pay period/
    assert_select 'td', /9:00 AM – 5:00 PM/
    assert_select 'td', /9:00 AM – 7:30 PM/
    assert_select 'td.num', '+2.50'
    assert_select "form[data-square-review='#{@card.id}'] button[value=accept]"

    seen_key = SquareTimecardReviewer.new(@card).comparison[:seen_key]
    post people_square_timecard_review_path(@card), params: { square_review: { decision: 'accept', reason: 'Closed the register late', seen_key: seen_key } }
    assert_redirected_to people_square_timecard_reviews_path
    follow_redirect!
    assert_select '.empty-state-title', 'No Square changes to review.'
    assert_equal 37_800, @card.reload.payable_seconds

    get people_square_timesheet_path(@card)
    assert_response :success
    assert_select '[data-square-history] li', 3
    assert_select '[data-square-history]', /Closed the register late/
    assert_select '[data-square-history]', /Square’s version accepted/
  end

  test 'a missing reason or stale view changes nothing' do
    post login_path, params: { email: @admin.email, password: 'password' }
    post people_square_timecard_review_path(@card), params: { square_review: { decision: 'accept', reason: '', seen_key: 'old' } }
    assert_redirected_to people_square_timecard_reviews_path
    assert_equal 'Say why, in a few words.', flash[:alert]
    post people_square_timecard_review_path(@card), params: { square_review: { decision: 'accept', reason: 'ok', seen_key: 'old' } }
    assert_match(/newer version/, flash[:alert])
    assert_equal 'changed', @card.reload.import_status
    assert_equal 0, SquareTimecardReview.count
  end

  test 'staff cannot open the review list or decide, even on their own card' do
    post login_path, params: { email: @staff.email, password: 'password123' }
    get people_square_timecard_reviews_path
    assert_response :redirect
    seen_key = SquareTimecardReviewer.new(@card).comparison[:seen_key]
    post people_square_timecard_review_path(@card), params: { square_review: { decision: 'accept', reason: 'mine', seen_key: seen_key } }
    assert_response :redirect
    assert_equal 'changed', @card.reload.import_status
    get people_square_timesheet_path(@card)
    assert_response :success
    assert_select 'form[data-square-review]', 0
    assert_select '[data-square-history] li', 2
  end

  test 'a timesheet covering an edited day is flagged' do
    sheet = People::Timesheet.create!(employee: @worker, period_start: '2026-10-01', period_end: '2026-10-07')
    post login_path, params: { email: @admin.email, password: 'password' }
    get people_timesheet_path(sheet)
    assert_response :success
    assert_select '[data-square-changes]', /Square edited 1 timecard/
    assert_select '[data-square-changes] a[href=?]', people_square_timecard_reviews_path(employee_id: @worker.id)
  end
end
