# frozen_string_literal: true

module People
  class LeaveRequestPolicy < ApplicationPolicy
    def index?
      module?('leave.read')
    end

    def show?
      index? && tenant?
    end

    def create?
      module?('leave.write')
    end

    def new?
      create?
    end

    def destroy?
      module?('leave.write') && tenant?
    end

    def approve?
      module?('leave.write') && tenant? && in_store_scope?
    end

    def deny?
      module?('leave.write') && tenant? && in_store_scope?
    end

    def cancel?
      module?('leave.write') && tenant? && in_store_scope?
    end

    private

    # A manager limited to stores decides only for staff of those stores.
    def in_store_scope?
      People::StoreScope.covers?(user, record.employee)
    end
  end
end
