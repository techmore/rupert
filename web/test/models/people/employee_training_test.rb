# frozen_string_literal: true

require 'test_helper'

class People::EmployeeTrainingTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  def employee(**attributes)
    People::Employee.new(first_name: 'Training', last_name: 'Flag', **attributes)
  end

  test 'in training only within the training dates' do
    trainee = employee(in_training: true, training_starts_on: Date.new(2026, 10, 1), training_ends_on: Date.new(2026, 10, 31))
    assert_not trainee.in_training_on?(Date.new(2026, 9, 30))
    assert trainee.in_training_on?(Date.new(2026, 10, 1))
    assert trainee.in_training_on?(Date.new(2026, 10, 31))
    assert_not trainee.in_training_on?(Date.new(2026, 11, 1))
    assert trainee.in_training_during?(Date.new(2026, 10, 29), Date.new(2026, 11, 4))
    assert_not trainee.in_training_during?(Date.new(2026, 11, 1), Date.new(2026, 11, 7))
  end

  test 'no end date means ongoing, and the flag off means not in training' do
    ongoing = employee(in_training: true, training_starts_on: Date.new(2026, 10, 1))
    assert ongoing.in_training_on?(Date.new(2027, 6, 1))
    assert_not employee(in_training: false, training_starts_on: Date.new(2026, 10, 1)).in_training_on?(Date.new(2026, 10, 5))
  end

  test 'a trainee needs a start date and the end cannot come before it' do
    missing = employee(in_training: true)
    assert_not missing.valid?
    assert missing.errors[:training_starts_on].any?
    backwards = employee(in_training: true, training_starts_on: Date.new(2026, 10, 10), training_ends_on: Date.new(2026, 10, 1))
    assert_not backwards.valid?
    assert backwards.errors[:training_ends_on].any?
    assert employee(in_training: false).valid?
  end
end
