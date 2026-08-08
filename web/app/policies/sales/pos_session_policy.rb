# frozen_string_literal: true

module Sales
  class PosSessionPolicy < ApplicationPolicy
    def index?
      module?("sales.read")
    end

    def show?
      index? && tenant?
    end

    def create?
      module?("sales.write")
    end

    def new?
      create?
    end

    def refresh?
      module?("sales.write") && tenant?
    end

    def close?
      module?("sales.write") && tenant?
    end

    def reopen?
      module?("sales.write") && tenant?
    end
  end
end
