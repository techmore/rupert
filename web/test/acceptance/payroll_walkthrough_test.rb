# frozen_string_literal: true

require 'test_helper'
require_relative 'walkthrough_helper'

# #424: deterministic synthetic pay run from approved timesheets through draft, a correction, finalize, export and
# paid, under the owner's pay rules (#423: overtime off, no rounding, admins get no commission or tips) and the labelled
# 15% deduction placeholder (#425). Retries (a second pay run for the same week, regenerate, finalize, pay) must not
# duplicate pay.
#
# Hand-computed expectations (week Thu 2026-10-01 .. Wed 2026-10-07; deductions = round(gross x 0.15), half a cent up):
#   Sam Staff  (employee, $15.00/h): 8.00 clock + 7.25 hand          = 15.25 h x 1500 = 22,875c; ded  3,431; net 19,444
#   Casey Clerk (employee, $16.50/h): 8 + 8 + 6 + 5 marked overtime  = 27.00 h x 1650 = 44,550c; ded  6,683; net 37,867
#     corrected in draft to 8 + 8 + 4 + 5                            = 25.00 h x 1650 = 41,250c; ded  6,188; net 35,062
#     (overtime is off, so the 5 h marked overtime are paid at straight time)
#   Ada Owner  (admin,    $20.00/h): 6.00 clock + 4.00 hand          = 10.00 h x 2000 = 20,000c; ded  3,000; net 17,000
#   Drew Draft (draft timesheet, never submitted)                     = not paid
#   Run after the correction: gross 84,125c, deductions 12,619c, net 71,506c.
# A $110 sale at 12:00 on 2026-10-01 ($100 before tax, $6 tip) while Sam and Ada were clocked in: Sam's estimate shows
# 1% commission = 100c and the whole 600c tip; Ada (admin) shows 0 and 0. Neither reaches a payslip (#425).
class PayrollWalkthroughTest < ActionDispatch::IntegrationTest
  include WalkthroughHelper

  setup do
    synthetic_workspace('Walkthrough payroll')
    @owner, @ada = person('pay-owner@example.test', 'admin', 'Ada', 'Owner', rate_cents: 2000)
    @leader = User.create!(tenant: @tenant, email: 'pay-leader@example.test', name: 'Lee Leader', role: 'shift_leader', password: PASSWORD)
    @sam_user, @sam = person('pay-sam@example.test', 'employee', 'Sam', 'Staff', rate_cents: 1500)
    @casey_user, @casey = person('pay-casey@example.test', 'employee', 'Casey', 'Clerk', rate_cents: 1650)
    @drew_user, @drew = person('pay-drew@example.test', 'employee', 'Drew', 'Draft', rate_cents: 1400)
    Current.reset
  end

  test 'pay run from approved timesheets through correction, finalize, export and paid' do
    tenant_scope do
      rules = PayRules.current
      assert_equal ['weekly', 'thursday', false, false], [rules.pay_period, rules.week_start_day, rules.overtime_enabled?, rules.chosen?]
    end
    step 'Pay rules', 'weekly Thursday-Wednesday (default, not yet chosen), overtime off'

    # Clock punches: Sam from the staff app, Ada from the web time clock.
    at('2026-10-01 09:00') { post '/api/v1/employee/clock', params: { request_token: 'payroll-walk-sam-01' }, headers: app_login(@sam_user), as: :json }
    at('2026-10-01 10:00') do
      sign_in(@owner)
      post clock_in_time_clock_path, params: { request_token: 'payroll-walk-ada-01' }
    end
    at('2026-10-01 16:00') do
      sign_in(@owner)
      post clock_out_time_clock_path, params: { shift_id: own_shift(@ada).id }
    end
    at('2026-10-01 17:00') { patch "/api/v1/employee/clock/#{own_shift(@sam).id}", headers: app_login(@sam_user), as: :json }
    sale_at('2026-10-01 12:00')
    step 'Clock: Sam 09:00-17:00 (8 h, staff app), Ada 10:00-16:00 (6 h, web); a $110 sale ($100 before tax, $6 tip) at 12:00'

    # Timesheets.
    at('2026-10-08 08:00') do
      auth = app_login(@sam_user)
      post '/api/v1/employee/timesheets', params: { timesheet: { period_start: '2026-10-01', period_end: '2026-10-07' } }, headers: auth, as: :json
      sam_sheet = response.parsed_body.dig('data', 'id')
      post "/api/v1/employee/timesheets/#{sam_sheet}/actions/import_shifts", headers: auth, as: :json
      post "/api/v1/employee/timesheets/#{sam_sheet}/entries", headers: auth, as: :json, params: { timesheet_entry: { worked_on: '2026-10-02', hours: '7.25', work_type: 'regular' } }
      post "/api/v1/employee/timesheets/#{sam_sheet}/actions/submit", headers: auth, as: :json
      assert_equal ['submitted', '15.25'], [response.parsed_body.dig('data', 'status'), response.parsed_body.dig('data', 'total_hours')]

      sign_in(@owner)
      @ada_sheet = web_sheet(@ada, [['2026-10-03', '4', 'regular']], import: true)
      @casey_sheet = web_sheet(@casey, [['2026-10-01', '8', 'regular'], ['2026-10-02', '8', 'regular'], ['2026-10-03', '6', 'regular'], ['2026-10-04', '5', 'overtime']])
      @drew_sheet = web_sheet(@drew, [['2026-10-01', '6', 'regular']], submit: false)
      post approve_people_timesheet_path(@ada_sheet)
      tenant_scope { assert People::Timesheet.find(@ada_sheet).submitted? }

      sign_in(@leader)
      [sam_sheet, @ada_sheet, @casey_sheet].each { |id| post approve_people_timesheet_path(id) }
      tenant_scope do
        assert_equal %w[approved approved approved draft], [sam_sheet, @ada_sheet, @casey_sheet, @drew_sheet].map { |id| People::Timesheet.find(id).status }
      end
    end
    step 'Timesheets: Sam 15.25 h (app), Ada 10 h, Casey 27 h incl. 5 h marked overtime, Drew 6 h left in draft',
      'owner could not approve own sheet; shift leader approved Sam, Ada, Casey; Drew stays draft'

    at('2026-10-09 09:00') do
      sign_in(@owner)
      # Draft pay run.
      post people_pay_runs_path, params: { pay_run: { name: 'Walkthrough pay week 1', period_start: '2026-10-01', period_end: '2026-10-07' } }
      @run = tenant_scope { People::PayRun.find_by!(name: 'Walkthrough pay week 1') }
      assert_equal({ 'Sam Staff' => [15.25, 22_875, 3431, 19_444], 'Ada Owner' => [10, 20_000, 3000, 17_000], 'Casey Clerk' => [27, 44_550, 6683, 37_867] }, slips)
      step 'Draft pay run 2026-10-01..07', "3 payslips #{slips.inspect}; Drew (draft) excluded"

      # Retries cannot duplicate pay.
      post people_pay_runs_path, params: { pay_run: { name: 'Walkthrough pay week 1 (double click)', period_start: '2026-10-01', period_end: '2026-10-07' } }
      assert_response :unprocessable_entity
      post people_pay_runs_path, params: { pay_run: { name: 'Overlapping', period_start: '2026-10-05', period_end: '2026-10-11' } }
      assert_response :unprocessable_entity
      tenant_scope { assert_equal 1, People::PayRun.count }
      2.times { post generate_payslips_people_pay_run_path(@run) }
      assert_equal 3, slips.size
      assert_equal [87_425, 74_311], totals
      step 'Retry: a second pay run for the same or an overlapping week; regenerate twice',
        'both second runs refused (only one pay run); regenerate keeps 3 payslips, gross $874.25, net $743.11'

      # Correction in draft: Casey's 2026-10-03 was 4 h, not 6.
      post reopen_people_timesheet_path(@casey_sheet)
      assert_match(/included in payroll/, flash[:alert])
      casey_slip = tenant_scope { @run.payslips.find_by!(employee_id: @casey.id) }
      post remove_payslip_people_pay_run_path(@run, payslip_id: casey_slip.id)
      post reopen_people_timesheet_path(@casey_sheet)
      tenant_scope do
        sheet = People::Timesheet.find(@casey_sheet)
        assert sheet.draft?
        entry = sheet.entries.find_by!(worked_on: '2026-10-03')
        post update_entry_people_timesheet_path(sheet, entry_id: entry.id), params: { _method: :patch, timesheet_entry: { worked_on: '2026-10-03', hours: '4', work_type: 'regular' } }
      end
      post submit_people_timesheet_path(@casey_sheet)
      sign_in(@leader)
      post approve_people_timesheet_path(@casey_sheet)
      sign_in(@owner)
      post generate_payslips_people_pay_run_path(@run)
      assert_equal [25, 41_250, 6188, 35_062], slips.fetch('Casey Clerk')
      assert_equal [84_125, 71_506], totals
      step 'Correction in draft: reopen Casey (refused while paid in the run), remove the payslip, reopen, 10-03 6 h -> 4 h, resubmit, approve, regenerate',
        'Casey 25 h x $16.50 = $412.50, ded $61.88, net $350.62; run gross $841.25, net $715.06'

      # Owner rules on the display-only estimate; nothing extra reaches the payslips.
      tenant_scope do
        sam_pay = EmployeePayWeek.new(employee: @sam, week_of: Date.new(2026, 10, 1))
        ada_pay = EmployeePayWeek.new(employee: @ada, week_of: Date.new(2026, 10, 1))
        assert_equal [100, 600], [sam_pay.commission_cents, sam_pay.tip_cents]
        assert_equal [true, 0, 0], [ada_pay.admin?, ada_pay.commission_cents, ada_pay.tip_cents]
      end
      assert_equal 22_875, slips.fetch('Sam Staff')[1]
      step 'Commission and tips (owner rules)', "Sam's estimate: 1% of $100 = $1.00 commission + whole $6 tip; Ada (admin) $0/$0; payslips unchanged (display only, #425)"

      get people_pay_run_path(@run)
      assert_response :success
      assert_includes response.body, 'Deductions (estimate)'
      assert_includes response.body, '15% placeholder estimate'
      assert_select 'td.num', text: '15.25'
      assert_includes response.body, '$841.25'
      step 'Pay run page', 'shows 15.25 h, gross $841.25 and the "Deductions (estimate)" / 15% placeholder labels'

      # A manual payslip is entered in dollars.
      post add_payslip_people_pay_run_path(@run), params: { payslip: { employee_id: @drew.id, gross: '25.00', deductions: '0', hours: '0' } }
      drew_slip = tenant_scope { @run.payslips.find_by!(employee_id: @drew.id) }
      assert_equal [2500, 0, 2500], [drew_slip.gross_cents, drew_slip.deductions_cents, drew_slip.net_cents]
      post remove_payslip_people_pay_run_path(@run, payslip_id: drew_slip.id)
      step 'Manual payslip: $25.00 for Drew, then removed', 'stored 2,500c (dollars field), removed; run back to 3 payslips'

      # Finalize, retries refused.
      post finalize_people_pay_run_path(@run)
      tenant_scope { assert_equal ['finalized', 84_125, 71_506], [@run.reload.status, @run.read_attribute(:total_gross_cents), @run.read_attribute(:total_net_cents)] }
      post finalize_people_pay_run_path(@run)
      assert_equal 'This pay run is already finalized.', flash[:alert]
      post generate_payslips_people_pay_run_path(@run)
      assert_equal 'Only draft pay runs can be regenerated.', flash[:alert]
      post add_payslip_people_pay_run_path(@run), params: { payslip: { employee_id: @drew.id, gross: '25.00' } }
      assert_equal 'Only draft pay runs can be edited.', flash[:alert]
      assert_equal 3, slips.size
      step 'Finalize; then finalize again, regenerate and add a payslip', 'finalized with stored gross 84,125c / net 71,506c; all three retries refused, still 3 payslips'

      # Export.
      get people_pay_run_path(@run, format: :csv)
      assert_response :success
      rows = CSV.parse(response.body, headers: true)
      assert_equal [['Ada Owner', '10.00', '20.00', '200.00', '30.00', '170.00'],
                    ['Casey Clerk', '25.00', '16.50', '412.50', '61.88', '350.62'],
                    ['Sam Staff', '15.25', '15.00', '228.75', '34.31', '194.44']],
        rows.map { |r| [r['Staff member'], r['Hours'], r['Hourly rate'], r['Gross'], r['Deductions (estimate)'], r['Net']] }
      assert(rows.all? { |r| r['Status'] == 'finalized' && r['Period start'] == '2026-10-01' && r['Period end'] == '2026-10-07' })
      assert_includes response.body, 'placeholder'
      step 'CSV export', '3 rows; Ada 10.00 h $200.00/$30.00/$170.00, Casey 25.00 h $412.50/$61.88/$350.62, Sam 15.25 h $228.75/$34.31/$194.44'

      # Paid.
      post pay_people_pay_run_path(@run)
      tenant_scope { assert_equal ['paid', Date.new(2026, 10, 9)], [@run.reload.status, @run.paid_on] }
      post pay_people_pay_run_path(@run)
      assert_equal 'Finalize the pay run before paying.', flash[:alert]
      tenant_scope { assert_equal Date.new(2026, 10, 9), @run.reload.paid_on }
      step 'Mark paid; then mark paid again', 'paid on 2026-10-09; the retry is refused and the paid date is unchanged'

      actions = tenant_scope { ActivityLog.where(tenant_id: @tenant.id, action: %w[pay_run_created pay_run_finalized pay_run_paid data_exported]).order(:id).pluck(:action) }
      assert_equal %w[pay_run_created pay_run_finalized data_exported pay_run_paid], actions
      step 'Activity log', actions.join(', ')
    end
  end

  private

  def own_shift(employee)
    tenant_scope { ClockShift.where(employee_id: employee.id).order(:id).last }
  end

  def sale_at(local_time)
    tenant_scope do
      order = Core::Order.new(source: 'shopify', source_order_id: "walk-#{SecureRandom.hex(4)}", occurred_at: Time.zone.parse(local_time),
        gross_cents: 11_600, tax_cents: 1000, tip_cents: 600, currency: 'USD')
      order.aasm.current_state = :paid
      order.save!
      order.order_lines.create!(name: 'Synthetic merchandise', unit_cents: 10_000, quantity: 1, line_cents: 10_000)
      order.payments.create!(method: 'card', amount_cents: 11_600, status: 'completed', paid_at: order.occurred_at)
    end
  end

  # Owner builds a sheet in the browser: create, optional clock import, hand entries, optional submit.
  def web_sheet(employee, entries, import: false, submit: true)
    post people_timesheets_path, params: { timesheet: { employee_id: employee.id, period_start: '2026-10-01', period_end: '2026-10-07' } }
    id = tenant_scope { People::Timesheet.find_by!(employee_id: employee.id, period_start: '2026-10-01').id }
    post import_shifts_people_timesheet_path(id) if import
    entries.each do |day, hours, type|
      post add_entry_people_timesheet_path(id), params: { timesheet_entry: { worked_on: day, hours: hours, work_type: type } }
    end
    post submit_people_timesheet_path(id) if submit
    id
  end

  # { name => [hours, gross, deductions, net] } for the walkthrough run.
  def slips
    tenant_scope do
      @run.reload.payslips.includes(:employee).to_h do |slip|
        hours = slip.hours.to_d
        [slip.employee.name, [hours == hours.to_i ? hours.to_i : hours.to_f, slip.gross_cents, slip.deductions_cents, slip.net_cents]]
      end
    end
  end

  def totals
    tenant_scope { [@run.reload.total_gross_cents, @run.total_net_cents] }
  end
end
