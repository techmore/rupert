# frozen_string_literal: true

module People
  class EmployeePolicy < ApplicationPolicy
    def show?
      module?('hr.read') && tenant?
    end

    def create?
      module?('hr.write')
    end

    def new?
      create?
    end

    def update?
      module?('hr.write') && tenant?
    end

    def edit?
      update?
    end

    def destroy?
      module?('hr.write') && tenant?
    end

    def deactivate?
      update?
    end

    def activate?
      update?
    end

    def transition?
      update?
    end
  end
end
