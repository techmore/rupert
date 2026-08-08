# frozen_string_literal: true

module Goals
  class KpiPolicy < ApplicationPolicy
    def show?
      module?("projects.read") && tenant?
    end

    def create?
      module?("projects.write")
    end

    def new?
      create?
    end

    def update?
      module?("projects.write") && tenant?
    end

    def destroy?
      module?("projects.write") && tenant?
    end
  end
end
