# frozen_string_literal: true

module People
  class DepartmentPolicy < ApplicationPolicy
    def index?
      module?('hr.read')
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
  end
end
