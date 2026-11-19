# frozen_string_literal: true

require 'csv'

# The provider-agnostic payroll file: one row per employee per pay period. Hours by kind, the rate
# on record, tips split card/cash, commission and bonuses, and an estimated gross that is the sum of
# the money columns. Money is dollars with two decimals, hours with two decimals. Cells that start
# with a formula character are neutralised like every other Rupert CSV.
class PayrollExport
  COLUMNS = %w[employee_number name email period_start period_end regular_hours overtime_hours daily_overtime_hours pto_hours sick_hours
               personal_hours holiday_hours unpaid_hours hourly_rate salary card_tips cash_tips commission bonuses estimated_gross notes].freeze

  def self.csv(period, summary: nil)
    summary ||= People::PayPeriodSummary.new(period)
    CSV.generate do |out|
      out << COLUMNS
      summary.rows.each do |row|
        out << [row.employee.employee_number, row.employee.name, row.employee.email, period.starts_on.iso8601, period.ends_on.iso8601,
                hours(row.regular_hours), hours(row.overtime_hours), hours(row.daily_overtime_hours), hours(row.pto_hours), hours(row.sick_hours),
                hours(row.personal_hours), hours(row.holiday_hours), hours(row.unpaid_hours),
                row.hourly_rate_cents ? money(row.hourly_rate_cents) : '', row.salary_cents ? money(row.salary_cents) : '',
                money(row.card_tips_cents), money(row.cash_tips_cents), money(row.commission_cents), money(row.bonus_cents),
                money(row.estimated_gross_cents), row.notes.join('; ')].map { |value| cell(value) }
      end
    end
  end

  def self.sha256(csv) = Digest::SHA256.hexdigest(csv)
  def self.filename(period) = "payroll-#{period.starts_on.iso8601}-#{period.ends_on.iso8601}.csv"
  def self.hours(value) = format('%.2f', value.to_d)
  def self.money(cents) = format('%.2f', cents.to_i / 100.0)

  def self.cell(value)
    text = value.to_s
    text.match?(/\A[=+\-@\t\r\n]/) ? "'#{text}" : text
  end
end
