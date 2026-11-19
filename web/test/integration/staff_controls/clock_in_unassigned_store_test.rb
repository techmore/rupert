# frozen_string_literal: true

require 'test_helper'

# Characterization: pins behaviour pending owner decision (docs/decisions/staff-controls-2026-11.md, item g).
# A worker assigned to one store can clock in at another: the store sent with the punch is saved
# as given and is not compared with the worker's own stores.
class StaffControlsClockInUnassignedStoreTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @home = Location.create!(source: 'ctrax', externalId: 'staff-controls/home', name: 'Home store')
    @other = Location.create!(source: 'ctrax', externalId: 'staff-controls/other', name: 'Other store')
    @user = User.create!(tenant: Current.tenant, email: 'clock-staff@example.test', password: 'password123', role: 'employee', name: 'Sam Staff')
    @worker = People::Employee.create!(user: @user, first_name: 'Sam', last_name: 'Staff', employment_type: 'part_time', location_ids: [@home.id])
    sign_in @user
  end
  teardown { Current.reset }

  test 'a worker assigned to one store clocks in at a different store' do
    assert @worker.works_at?(@home.id)
    assert_not @worker.works_at?(@other.id)

    assert_difference -> { ClockShift.count }, 1 do
      post clock_in_time_clock_path, params: { request_token: SecureRandom.uuid, location_id: @other.id }
    end

    assert_equal @other.id.to_s, ClockShift.sole.location_id.to_s
  end
end
