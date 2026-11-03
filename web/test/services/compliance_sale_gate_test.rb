# frozen_string_literal: true

require 'test_helper'
require_relative '../support/compliance_fixtures'

# F70 manager PIN overrides and the compliance audit trail.
class ComplianceSaleGateTest < ActiveSupport::TestCase
  include ComplianceFixtures

  setup do
    Current.tenant = tenants(:default_tenant)
    @location = compliance_store
    approve!(@location, '22', name: 'Hemp Flower 3.5g', category: cash_category, card: false)
    @cashier = cashier
    Current.user = @cashier
    @manager = manager_with_pin
  end
  teardown { Current.reset }

  test 'ID confirmation is required for age-restricted items and cannot be overridden' do
    result = evaluate('cash', id_checked: false)
    assert_equal [:id_not_checked], result.blocking.map(&:code)
    assert_not result.overridable?
    assert evaluate('cash', id_checked: true).allowed?
  end

  test 'a blocked sale without an override is logged and raised with its issues' do
    error = assert_raises(Compliance::Blocked) { enforce(evaluate('card'), nil) }
    assert_equal false, error.payload[:compliance][:allowed]
    assert_equal true, error.payload[:compliance][:overridable]
    event = ComplianceEvent.sole
    assert_equal ['sale_blocked', @cashier.id, @location.id], [event.action, event.user_id, event.location_id]
    assert_equal ['card_ineligible'], event.details['issues'].map { |i| i['code'] }
  end

  test 'a manager PIN and reason approve an overridable block and are logged' do
    approver = enforce(evaluate('card'), override(@manager, '4321', 'Customer has no cash; owner approved by phone'))
    assert_equal @manager, approver
    event = ComplianceEvent.sole
    assert_equal ['override_granted', @manager.id, 'Customer has no cash; owner approved by phone'], [event.action, event.approver_id, event.reason]
  end

  test 'wrong PIN, short reason, non-manager and non-overridable issues are refused and logged' do
    assert_raises(Compliance::OverrideRefused) { enforce(evaluate('card'), override(@manager, '9999', 'A good long reason here')) }
    assert_raises(Compliance::OverrideRefused) { enforce(evaluate('card'), override(@manager, '4321', 'short')) }
    other_cashier = cashier
    other_cashier.update!(pos_override_pin_digest: BCrypt::Password.create('1111'))
    assert_raises(Compliance::OverrideRefused) { enforce(evaluate('card'), override(other_cashier, '1111', 'A good long reason here')) }
    not_overridable = evaluate('card', id_checked: false)
    assert_raises(Compliance::OverrideRefused) { enforce(not_overridable, override(@manager, '4321', 'A good long reason here')) }
    assert_equal %w[wrong_pin reason_missing not_approver not_overridable], ComplianceEvent.order(:id).map { |e| e.details['refusal'] }
    assert ComplianceEvent.all.all? { |e| e.action == 'override_refused' }
  end

  test 'five wrong PINs lock the manager out for fifteen minutes, even with the right PIN' do
    5.times { assert_raises(Compliance::OverrideRefused) { enforce(evaluate('card'), override(@manager, '0000', 'A good long reason here')) } }
    error = assert_raises(Compliance::OverrideRefused) { enforce(evaluate('card'), override(@manager, '4321', 'A good long reason here')) }
    assert_match(/Too many wrong PINs/, error.message)
    travel 16.minutes do
      assert_equal @manager, enforce(evaluate('card'), override(@manager, '4321', 'A good long reason here'))
    end
  end

  test 'a manager from another workspace cannot approve' do
    other = create_workspace('Other', current: false)
    outsider = Current.set(tenant: other) { manager_with_pin(pin: '4321') }
    error = assert_raises(Compliance::OverrideRefused) { enforce(evaluate('card'), override(outsider, '4321', 'A good long reason here')) }
    assert_match(/Choose a manager/, error.message)
    assert_not_includes Compliance::SaleGate.approvers, outsider
    assert_includes Compliance::SaleGate.approvers, @manager
  end

  test 'audit rows are append-only' do
    assert_raises(Compliance::Blocked) { enforce(evaluate('card'), nil) }
    assert_raises(ActiveRecord::ReadOnlyRecord) { ComplianceEvent.sole.update!(reason: 'edited') }
  end

  test 'PINs are stored only as a digest and must be 4 to 8 digits' do
    assert_not_includes @manager.pos_override_pin_digest, '4321'
    assert @manager.valid_pos_override_pin?('4321')
    assert_not @manager.valid_pos_override_pin?('43210')
    assert_raises(ArgumentError) { @manager.pos_override_pin = '12ab' }
    assert_raises(ArgumentError) { @manager.pos_override_pin = '123' }
  end

  private

  def evaluate(tender, id_checked: true)
    lines = Compliance::ItemEligibility.lines_for_ctrax(location: @location, variant_ids: %w[22])
    Compliance::SaleGate.evaluate(lines, tender: tender, id_checked: id_checked, policy: CompliancePolicy.for(@location))
  end

  def enforce(result, override) = Compliance::SaleGate.enforce!(result, override: override, location_id: @location.id)

  def override(user, pin, reason) = Compliance::SaleGate::Override.new(approver_id: user.id.to_s, pin: pin, reason: reason)
end
