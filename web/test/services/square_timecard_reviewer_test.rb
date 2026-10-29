# frozen_string_literal: true

require 'test_helper'

class SquareTimecardReviewerTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    Current.user = users(:regular_user)
    @worker = People::Employee.create!(first_name: 'Square', last_name: 'Worker')
    @identity = EmployeeSourceIdentity.create!(employee: @worker, source: 'square', external_id: 'native-team-1')
  end
  teardown { Current.reset }

  def card(id = 'native-card-1', **attributes)
    { 'id' => id, 'team_member_id' => @identity.external_id, 'location_id' => 'native-location-1', 'timezone' => 'America/New_York',
      'start_at' => '2026-10-05T09:00:00-04:00', 'end_at' => '2026-10-05T17:00:00-04:00', 'status' => 'CLOSED', 'version' => 1,
      'updated_at' => '2026-10-06T10:00:00Z', 'wage' => { 'hourly_rate' => { 'amount' => 2000, 'currency' => 'USD' } } }.merge(attributes.stringify_keys)
  end

  def import(rows)
    SquareTimecardImport.new(rows: rows).call(apply: true)
  end

  def edited
    card(end_at: '2026-10-05T18:00:00-04:00', version: 2, updated_at: '2026-10-07T10:00:00Z')
  end

  def reviewer(record = SquareTimecard.first, user: Current.user)
    SquareTimecardReviewer.new(record.reload, reviewer: user)
  end

  def decide(decision, reason: 'Checked with the shift lead', user: Current.user)
    review = reviewer(user: user)
    review.public_send(decision, reason: reason, seen_key: review.comparison[:seen_key])
  end

  def summary_hours
    EmployeeWorkSummary.new(employee: @worker, from: Date.new(2026, 10, 1), to: Date.new(2026, 10, 10)).hours
  end

  test 'every distinct Square version and each missing read is appended, never rewritten' do
    import([card])
    import([card])
    assert_equal 1, SquareTimecardVersion.count
    import([edited])
    import([card])
    import([])
    import([])
    versions = SquareTimecardVersion.chronological.to_a
    assert_equal %w[seen seen seen missing], versions.map(&:kind)
    assert_equal [1, 2, 1, nil], versions.map(&:source_version)
    assert_equal versions.first.digest, versions.third.digest
    refute_includes versions.first.payload_before_type_cast, 'native-team-1'
    assert_raises(ActiveRecord::ReadOnlyRecord) { versions.first.update!(seen_at: Time.current) }
    assert_raises(ActiveRecord::ReadOnlyRecord) { versions.first.destroy! }
  end

  test 'cards imported before the history existed get their original payload as version one' do
    import([card])
    SquareTimecardVersion.delete_all
    import([edited])
    assert_equal [1, 2], SquareTimecardVersion.chronological.pluck(:source_version)
    assert_equal SquareTimecard.first.imported_at.to_i, SquareTimecardVersion.chronological.first.seen_at.to_i
  end

  test 'accept rebuilds the counted days from Square latest version and records who when and why' do
    import([card])
    import([edited])
    assert_equal 8, summary_hours
    review = decide(:accept!)
    record = SquareTimecard.first
    assert_equal 'accepted', review.decision
    assert_equal users(:regular_user), review.reviewer
    assert_equal 'Checked with the shift lead', review.reason
    assert_equal [28_800, 32_400], [review.counted_payable_seconds, review.latest_payable_seconds]
    assert_equal 'imported', record.import_status
    assert_nil record.issue
    assert_equal 32_400, record.payable_seconds
    assert_equal [[Date.new(2026, 10, 5), 32_400]], record.days.pluck(:worked_on, :payable_seconds)
    assert_equal 9, summary_hours
    assert_equal 2, JSON.parse(record.source_payload)['version']
    assert ActivityLog.exists?(action: 'square_timecard_accepted')
    assert_raises(ActiveRecord::ReadOnlyRecord) { review.update!(reason: 'rewritten') }
    assert_raises(ActiveRecord::ReadOnlyRecord) { review.destroy! }

    result = import([edited])
    assert_equal({ 'imported' => 1 }, result[:statuses])
    assert_equal 9, summary_hours
    import([card])
    assert_equal 'changed', SquareTimecard.first.import_status
    assert_equal 9, summary_hours
  end

  test 'keep original keeps counted hours and stops the same edit being flagged, but a newer edit is flagged' do
    import([card])
    import([edited])
    review = decide(:keep!)
    assert_equal 'kept', review.decision
    assert_equal 'imported', SquareTimecard.first.import_status
    assert_equal 8, summary_hours
    import([edited])
    assert_equal 'imported', SquareTimecard.first.import_status
    import([card(end_at: '2026-10-05T19:00:00-04:00', version: 3)])
    assert_equal 'changed', SquareTimecard.first.import_status
    assert_equal 8, summary_hours
  end

  test 'accepting a removal counts no hours, stays removed, and a returning card is flagged again' do
    import([card])
    import([])
    assert_equal 'missing', SquareTimecard.first.import_status
    review = decide(:accept!)
    assert_equal 0, review.latest_payable_seconds
    assert_equal 'removed', SquareTimecard.first.import_status
    assert_equal 0, SquareTimecardDay.count
    assert_equal 0, summary_hours
    import([])
    assert_equal 'removed', SquareTimecard.first.import_status
    import([card])
    assert_equal 'changed', SquareTimecard.first.import_status
    decide(:accept!)
    assert_equal 8, summary_hours
  end

  test 'keeping hours Square removed is remembered until the card returns' do
    import([card])
    import([])
    decide(:keep!)
    assert_equal 'imported', SquareTimecard.first.import_status
    import([])
    assert_equal 'imported', SquareTimecard.first.import_status
    assert_equal 8, summary_hours
  end

  test 'a submitted approved or paid period is never changed: accept is held and the timesheet flagged' do
    import([card])
    import([edited])
    sheet = People::Timesheet.create!(employee: @worker, period_start: '2026-10-01', period_end: '2026-10-07')
    sheet.submit!
    sheet.approve!
    review = decide(:accept!)
    assert_equal 'held', review.decision
    assert_includes review.held_by, 'timesheet (approved)'
    record = SquareTimecard.first
    assert_equal 'changed', record.import_status
    assert_match(/locked/, record.issue)
    assert_equal 8, summary_hours
    assert_equal 28_800, record.days.sum(:payable_seconds)
    assert_equal ['square_edit_held'], sheet.events.pluck(:action)

    sheet.reopen!
    review = decide(:accept!)
    assert_equal 'accepted', review.decision
    assert_equal 9, summary_hours
  end

  test 'accept is refused when the latest version is open, overlaps other work, or is unmatched' do
    import([card])
    import([card(end_at: nil, status: 'OPEN', version: 2)])
    assert_raises(SquareTimecardReviewer::Error) { decide(:accept!) }
    import([edited])
    ClockShift.new(employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name, employment_type: @worker.employment_type,
      started_at: Time.iso8601('2026-10-05T17:30:00-04:00'), ended_at: Time.iso8601('2026-10-05T19:00:00-04:00'), request_token: SecureRandom.hex(12)).save!(validate: false)
    error = assert_raises(SquareTimecardReviewer::Error) { decide(:accept!) }
    assert_match(/overlap/, error.message)
    assert_equal 8, summary_hours
    assert_equal 0, SquareTimecardReview.count
  end

  test 'reviews need a reason, a fresh view, a manager, and someone other than the worker' do
    import([card])
    import([edited])
    assert_raises(SquareTimecardReviewer::Error) { decide(:accept!, reason: ' ') }
    stale = reviewer
    key = stale.comparison[:seen_key]
    import([card(end_at: '2026-10-05T19:00:00-04:00', version: 3)])
    error = assert_raises(SquareTimecardReviewer::Error) { stale.accept!(reason: 'ok', seen_key: key) }
    assert_match(/newer version/, error.message)

    staff = User.create!(tenant: tenants(:default_tenant), email: 'square-review-staff@example.invalid', password: 'password123', role: 'employee')
    assert_raises(Pundit::NotAuthorizedError) { decide(:accept!, user: staff) }
    leader = User.create!(tenant: tenants(:default_tenant), email: 'square-review-leader@example.invalid', password: 'password123', role: 'shift_leader')
    refute SquareTimecardReviewer.allowed?(leader)
    manager = User.create!(tenant: tenants(:default_tenant), email: 'square-review-manager@example.invalid', password: 'password123', role: 'manager')
    assert SquareTimecardReviewer.allowed?(manager)
    @worker.update!(user: manager)
    error = assert_raises(SquareTimecardReviewer::Error) { decide(:accept!, user: manager) }
    assert_match(/your own hours/, error.message)
    assert_equal 0, SquareTimecardReview.count
  end

  test 'history lists versions and decisions in order' do
    import([card])
    import([edited])
    decide(:keep!, reason: 'Square edit was a mistake')
    events = SquareTimecardReviewer.history(SquareTimecard.first)
    assert_equal %w[seen seen kept], events.map { |event| event[:kind] }
    assert_equal [28_800, 32_400], events.first(2).map { |event| event[:seconds] }
    assert_equal 'Square edit was a mistake', events.last[:reason]
  end
end
