# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/compliance_fixtures'

# Characterization: pins behaviour pending owner decision (docs/decisions/staff-controls-2026-11.md, item d).
# A manager's override PIN may be four digits. Wrong guesses are counted against the manager, not
# against the cashier who typed them: five in 15 minutes lock that manager's PIN for everyone.
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

  test 'a four digit PIN is accepted and three digits are refused' do
    user = User.new
    user.pos_override_pin = '1234'
    assert user.valid_pos_override_pin?('1234')
    assert_raises(ArgumentError) { user.pos_override_pin = '123' }
  end

  test 'five wrong PINs typed by one cashier lock the manager out for every cashier for 15 minutes' do
    Current.user = @guesser
    5.times { |n| assert_match(/PIN is not right/, refusal(pin: "111#{n}")) }

    Current.user = @colleague
    assert_match(/Too many wrong PINs/, refusal(pin: '4321'))
    assert_equal 'locked_out', ComplianceEvent.last.details['refusal']

    travel_to 16.minutes.from_now do
      assert_equal @manager, approve(pin: '4321')
    end
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
