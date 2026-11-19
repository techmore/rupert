# frozen_string_literal: true

require 'test_helper'
require_relative '../support/time_and_pay_helper'

# Stores on accounts and staff records: the forms save them and the scope helper reads them.
class LocationScopeTest < ActionDispatch::IntegrationTest
  include TimeAndPayHelper

  setup do
    time_and_pay_workspace
    @store_a = Location.create!(name: 'Store A', source: 'rupert', externalId: 'a', active: true)
    @store_b = Location.create!(name: 'Store B', source: 'rupert', externalId: 'b', active: true)
  end
  teardown { Current.reset }

  test 'the account form saves store limits for managers' do
    tp_sign_in(@admin)
    get edit_user_path(@manager)
    assert_select '[data-user-stores] input[type=checkbox]', count: 2
    patch user_path(@manager), params: { user: { name: 'Mia Manager', email: @manager.email, role: 'manager', location_ids: ['', @store_a.id] } }
    assert_equal [@store_a.id], @manager.reload.location_ids
    assert @manager.scoped_to_locations?
    assert @manager.manages_location?(@store_a.id)
    assert_not @manager.manages_location?(@store_b.id)
    patch user_path(@manager), params: { user: { name: 'Mia Manager', email: @manager.email, role: 'manager', location_ids: [''] } }
    assert_not @manager.reload.scoped_to_locations?
  end

  test 'the staff form saves stores and tip eligibility and the scope helper applies them' do
    tp_sign_in(@admin)
    get edit_people_employee_path(@worker)
    assert_select '[data-employee-stores] input[type=checkbox]', count: 2
    assert_select '[data-employee-tip-eligible] input[type=checkbox][checked]'
    patch people_employee_path(@worker), params: { employee: { first_name: 'Sam', last_name: 'Staff', employment_type: 'part_time', tip_eligible: '0', location_ids: ['', @store_b.id] } }
    @worker.reload
    assert_equal [@store_b.id], @worker.location_ids
    assert_not @worker.tip_eligible?
    @manager.update!(location_ids: [@store_a.id])
    assert_not People::StoreScope.covers?(@manager, @worker)
    assert_empty People::StoreScope.employees_for(@manager, base: People::Employee.where(id: @worker.id))
    _, everywhere = tp_person('Eve', 'Everywhere')
    assert People::StoreScope.covers?(@manager, everywhere), 'a worker with no stores works everywhere'
  end
end
