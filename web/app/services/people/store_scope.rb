# frozen_string_literal: true

module People
  # Which staff a manager or shift lead may act on. A user with no store limits sees everyone;
  # one limited to stores (User#location_ids) sees the staff who work at any of those stores
  # (Employee#works_at?: a worker with no stores of their own works everywhere).
  module StoreScope
    module_function

    # An ActiveRecord scope of People::Employee (default scope applies: merged profiles hidden).
    def employees_for(user, base: People::Employee.all)
      return base unless user&.scoped_to_locations?

      ids = base.select { |employee| user.location_ids.any? { |location_id| employee.works_at?(location_id) } }.map(&:id)
      base.where(id: ids)
    end

    # True when `user` may act on `employee`.
    def covers?(user, employee)
      return true unless user&.scoped_to_locations?
      return false if employee.nil?

      user.location_ids.any? { |location_id| employee.works_at?(location_id) }
    end

    # True when `user` may act on a record at `location_id` (nil = no store = everyone).
    def manages?(user, location_id)
      user.nil? || user.manages_location?(location_id)
    end
  end
end
