# frozen_string_literal: true

require 'csv'

# A pay run's payslips as CSV (#424): one row per payslip, amounts in dollars. Deductions not entered by hand are the
# flat 15% placeholder estimate (#425), and every row says so, so the file cannot be mistaken for real withholding.
class PayRunCsv
  HEADERS = ['Pay run', 'Period start', 'Period end', 'Status', 'Paid on', 'Staff member', 'Employee number', 'Pay type',
             'Hours', 'Hourly rate', 'Gross', 'Deductions (estimate)', 'Net', 'Note'].freeze
  NOTE = 'Deductions are a flat 15% placeholder estimate, not tax or withholding; needs payroll review before paying anyone.'

  def self.generate(pay_run)
    slips = pay_run.payslips.includes(:employee, :pay_rate).to_a.sort_by { |slip| [slip.employee&.name.to_s, slip.id] }
    CSV.generate do |out|
      out << HEADERS
      slips.each do |slip|
        rate = slip.pay_rate
        out << [pay_run.name, pay_run.period_start, pay_run.period_end, pay_run.status, pay_run.paid_on,
                slip.employee&.name, slip.employee&.employee_number, rate&.pay_type || 'manual',
                format('%.2f', slip.hours.to_d), rate&.pay_type == 'hourly' ? money(rate.hourly_rate_cents) : nil,
                money(slip.gross_cents), money(slip.deductions_cents), money(slip.net_cents), NOTE].map { |value| TimesheetCsv.cell(value) }
      end
    end
  end

  def self.money(cents) = format('%d.%02d', *cents.to_i.divmod(100))
end
