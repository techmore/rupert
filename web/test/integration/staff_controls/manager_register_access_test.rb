# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/compliance_fixtures'

# Characterization: pins behaviour pending owner decision (docs/decisions/staff-controls-2026-11.md, item e).
# The built-in manager role approves blocked sales with a PIN but cannot open the register or ring
# a sale itself (it has neither `pos.use` nor `sales.write`).
class StaffControlsManagerRegisterAccessTest < ActionDispatch::IntegrationTest
  include ComplianceFixtures

  setup do
    Current.tenant = tenants(:default_tenant)
    @location = compliance_store
    @manager = manager_with_pin
    sign_in @manager
  end
  teardown { Current.reset }

  test 'a manager can approve overrides but is refused the register and cannot pair a customer screen' do
    assert @manager.can_approve_pos_override?
    assert_includes Compliance::SaleGate.approvers, @manager
    assert_not @manager.can_use_pos?

    get ctrax_pos_path(location_id: @location.id)
    assert_redirected_to root_path
    assert_equal "You don't have permission to use the POS preview.", flash[:alert]
    assert_no_difference -> { PosDisplaySession.count } do
      post pos_displays_path, params: { location_id: @location.id }
    end
    assert_redirected_to root_path
    assert_equal "You don't have permission to do that.", flash[:alert]
  end
end
