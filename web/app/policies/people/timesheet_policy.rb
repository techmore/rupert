# frozen_string_literal: true

module People
  class TimesheetPolicy < ApplicationPolicy
    def index?
      module?('timesheets.read')
    end

    def show?
      index? && tenant?
    end

    def create?
      module?('timesheets.write')
    end

    def new?
      create?
    end

    def update?
      module?('timesheets.write') && tenant?
    end

    def edit?
      update?
    end

    def destroy?
      module?('timesheets.write') && tenant?
    end

    def submit?
      module?('timesheets.write') && tenant?
    end

    def approve?
      module?('timesheets.write') && tenant?
    end

    def reject?
      module?('timesheets.write') && tenant?
    end

    def reopen?
      module?('timesheets.write') && tenant?
    end

    def add_entry?
      module?('timesheets.write') && tenant?
    end

    def remove_entry?
      module?('timesheets.write') && tenant?
    end
  end
end
