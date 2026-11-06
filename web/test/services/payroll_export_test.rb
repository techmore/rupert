# frozen_string_literal: true

require 'test_helper'
require_relative '../support/time_and_pay_helper'

class PayrollExportTest < ActiveSupport::TestCase
  include TimeAndPayHelper

  setup { time_and_pay_workspace }
  teardown { Current.reset }

  test 'one row per employee with hours by kind, tips, commission and a neutralised note' do
    travel_to Time.zone.parse('2026-11-06 10:00') do
      PayRules.save!({ 'overtime_enabled' => true, 'overtime_threshold_hours' => '40', 'overtime_multiplier' => '1.5', 'pay_period' => 'weekly', 'week_start_day' => 'thursday' }, actor: @admin)
      sheet = tp_submitted_sheet!(@worker, '2026-10-29', { '2026-10-29' => 10, '2026-10-30' => 10, '2026-10-31' => 10, '2026-11-01' => 10, '2026-11-02' => 4 })
      sheet.update_columns(sales_cents: 50_000, card_redemptions: 1)
      TimesheetWorkflow.new(user: @manager).change(sheet, :approve, review_note: nil)
      _, salaried = tp_person('Sal', 'Salary', rate_cents: nil)
      People::PayRate.create!(employee: salaried, pay_type: 'salary', annual_salary_cents: 5_200_000, pay_frequency: 'weekly', effective_on: '2025-01-01')
      salaried.update!(employee_number: '=E-2')
      sal_sheet = tp_submitted_sheet!(salaried, '2026-10-29', { '2026-10-30' => 8 })
      TimesheetWorkflow.new(user: @manager).change(sal_sheet, :approve, review_note: nil)
      TipAllocation.create!(employee: @worker, source_kind: 'manual', tip_method: 'direct', amount_cents: 2000, occurred_at: Time.zone.parse('2026-10-30 13:00'), business_date: Date.new(2026, 10, 30))
      period = PayPeriod.for_date(Date.new(2026, 10, 29))
      csv = PayrollExport.csv(period)
      rows = CSV.parse(csv, headers: true)
      sam = rows.find { |r| r['name'] == 'Sam Staff' }
      # 44 h: 40 regular + 4 weekly overtime at 1.5x → 40*15 + 4*15*1.5 = 600 + 90 = 690; commission 1% of $500 = 5.00; bonus 10.00; tips 20.00
      assert_equal '40.00', sam['regular_hours']
      assert_equal '4.00', sam['overtime_hours']
      assert_equal '20.00', sam['card_tips']
      assert_equal '5.00', sam['commission']
      assert_equal '10.00', sam['bonuses']
      assert_equal '725.00', sam['estimated_gross']
      sal = rows.find { |r| r['name'] == 'Sal Salary' }
      assert_equal "'=E-2", sal['employee_number'], 'formula characters are neutralised'
      assert_equal '52000.00', sal['salary']
      assert_equal '1000.00', sal['estimated_gross'], 'weekly slice of the salary'
      assert_match(/Salaried/, sal['notes'])
      assert_equal 64, PayrollExport.sha256(csv).length
    end
  end
end
