# frozen_string_literal: true

module People
  # One employee's pay for one pay run: hours, gross, deductions, net.
  class Payslip < ApplicationRecord
    include TenantScoped

    self.table_name = "payslips"

    belongs_to :pay_run, class_name: "People::PayRun"
    belongs_to :employee, class_name: "People::Employee"
    belongs_to :pay_rate, class_name: "People::PayRate", optional: true

    validates :hours, numericality: { greater_than_or_equal_to: 0 }
    validates :gross_cents, :deductions_cents, :net_cents, numericality: { greater_than_or_equal_to: 0 }

    def display_number
      "P-#{pay_run.period_end.strftime("%Y%m")}-#{employee.id}"
    end
  end
end
