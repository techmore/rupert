# frozen_string_literal: true

require 'test_helper'

# The manager Tips page: period totals, by person, unassigned tips that can be assigned (audited),
# settlement matching, CSV, and the permission boundary.
class PeopleTipsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = users(:regular_user)
    @admin.update!(role: 'admin') unless @admin.can?('payroll.write')
    user = User.create!(tenant: @tenant, name: 'Tipped', email: 'tipped-worker@example.com', role: 'employee', password: 'password')
    @worker = People::Employee.create!(user: user, first_name: 'Tipped', last_name: 'Worker', employment_type: 'part_time')
    @at = Time.zone.parse('2026-11-05 13:00')
    TipAllocation.create!(employee: @worker, source_kind: 'dejavoo_feed_event', source_id: 1, tip_method: 'pool', status: 'settled', amount_cents: 700,
      gross_tip_cents: 700, share_count: 1, occurred_at: @at, business_date: @at.to_date, settlement_ref: 'dejavoo-batch:12', settled_at: @at + 9.hours)
    @orphan = TipAllocation.create!(source_kind: 'dejavoo_feed_event', source_id: 2, tip_method: 'pool', status: 'estimated', amount_cents: 250,
      gross_tip_cents: 250, share_count: 0, occurred_at: @at + 1.hour, business_date: @at.to_date, evidence: 'time_register')
    sign_in(@admin)
  end

  teardown { Current.reset }

  test 'shows the period, assigns an unassigned tip and downloads the CSV' do
    get people_tips_path(period: '2026-11-05')
    assert_response :success
    assert_select 'h1', 'Tips'
    assert_select '.stat', text: /Unassigned\s*\$2\.50/
    assert_select '.stat', text: /Settled\s*\$7\.00/
    assert_select '.pill-rose', 'Unassigned'
    assert_select 'td', 'Dejavoo batch 12'
    post assign_people_tips_path(period: '2026-11-05'), params: { allocation_id: @orphan.id, employee_id: @worker.id }
    assert_redirected_to people_tips_path(period: '2026-11-05')
    assert_equal 950, TipAllocation.where(employee_id: @worker.id).sum(:amount_cents)
    assert_equal 0, TipAllocation.where(employee_id: nil).sum(:amount_cents)
    assert ActivityLog.where(action: 'tips.assigned').exists?
    follow_redirect!
    assert_select '.empty-state-title', 'Nothing unassigned.'
    get people_tips_path(period: '2026-11-05', format: :csv)
    assert_response :success
    assert_includes response.body, 'Tipped Worker'
  end

  test 'the page is in the Team navigation and staff cannot open it' do
    get people_tips_path
    assert_select 'nav a', text: 'Tips'
    sign_in(@worker.user)
    get people_tips_path
    assert_redirected_to employee_app_path
  end
end
