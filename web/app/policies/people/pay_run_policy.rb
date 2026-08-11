# frozen_string_literal: true

module People
  class PayRunPolicy < ApplicationPolicy
    def index?
      module?("payroll.read")
    end

    def show?
      index? && tenant?
    end

    def create?
      module?("payroll.write")
    end

    def new?
      create?
    end

    def finalize?
      module?("payroll.write") && tenant?
    end

    def pay?
      module?("payroll.write") && tenant?
    end

    def generate_payslips?
      module?("payroll.write") && tenant?
    end

    def add_payslip?
      module?("payroll.write") && tenant?
    end

    def remove_payslip?
      module?("payroll.write") && tenant?
    end
  end
end
