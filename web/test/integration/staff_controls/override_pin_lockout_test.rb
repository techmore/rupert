# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/compliance_fixtures'

# Owner decision (docs/decisions/staff-controls-2026-11.md, item d): a new override PIN is six to
# eight digits, and wrong guesses count against the cashier who typed them (five in 15 minutes, ten
# in a day), so nobody can lock a manager's PIN for everyone else.
class StaffControlsOverridePinLockoutTest < ActiveSupport::TestCase
  include ComplianceFixtures

  setup do
    Current.tenant = tenants(:default_tenant)
    @location = compliance_store
    @manager = manager_with_pin(pin: '4321')
    @guesser = cashier
    @colleague = cashier
  end
  teardown { Current.reset }

  test 'a new PIN needs six digits; a four digit PIN set earlier still works' do
    user = User.new
    assert_raises(ArgumentError) { user.pos_override_pin = '1234' }
    user.pos_override_pin = '123456'
    assert user.valid_pos_override_pin?('123456')
    assert @manager.valid_pos_override_pin?('4321')
  end

  test 'five wrong PINs lock out the cashier who typed them, not the manager' do
    Current.user = @guesser
    5.times { |n| assert_match(/PIN is not right/, refusal(pin: "111#{n}")) }
    assert_match(/Too many wrong PINs from this sign-in/, refusal(pin: '4321'))
    assert_equal 'locked_out', ComplianceEvent.last.details['refusal']

    Current.user = @colleague
    assert_equal @manager, approve(pin: '4321')

    Current.user = @guesser
    travel_to 16.minutes.from_now do
      assert_equal @manager, approve(pin: '4321')
    end
  end

  test 'the lock follows the cashier to another manager' do
    other_manager = manager_with_pin(pin: '654321')
    Current.user = @guesser
    5.times { refusal(pin: '0000') }

    override = Compliance::SaleGate::Override.new(approver_id: other_manager.id.to_s, pin: '654321', reason: 'Owner approved card for this sale')
    assert_equal 'locked_out', Compliance::SaleGate.refusal_for(other_manager, override).first
  end

  test 'ten wrong PINs in a day lock the cashier out until the day has passed' do
    Current.user = @guesser
    2.times do |round|
      travel_to (round * 20).minutes.from_now do
        4.times { assert_match(/PIN is not right/, refusal(pin: '0000')) }
      end
    end
    travel_to 1.hour.from_now do
      2.times { assert_match(/PIN is not right/, refusal(pin: '0000')) }
    end

    travel_to(3.hours.from_now) { assert_match(/Too many wrong PINs/, refusal(pin: '4321')) }
    travel_to(26.hours.from_now) { assert_equal @manager, approve(pin: '4321') }
  end

  private

  def approve(pin:)
    issue = Compliance::ItemEligibility::Issue.new(code: :card_ineligible, severity: :block, overridable: true, item_key: '22', item_name: 'Hemp Flower 3.5g',
      message: 'Hemp Flower 3.5g is not approved for card sales.')
    override = Compliance::SaleGate::Override.new(approver_id: @manager.id.to_s, pin: pin, reason: 'Owner approved card for this sale')
    Compliance::SaleGate.enforce!(Compliance::ItemEligibility::Result.new([issue], :card), override: override, location_id: @location.id)
  end

  def refusal(pin:)
    assert_raises(Compliance::OverrideRefused) { approve(pin: pin) }.message
  end
end
