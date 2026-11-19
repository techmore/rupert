# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/compliance_fixtures'

# Owner decision (docs/decisions/staff-controls-2026-11.md, item a): a refund started by a cashier
# needs a manager to pick their name and type their override PIN. Owners and managers refund as before.
class StaffControlsRefundWithoutApprovalTest < ActionDispatch::IntegrationTest
  include ComplianceFixtures

  setup do
    Current.tenant = tenants(:default_tenant)
    @cashier = User.create!(tenant: Current.tenant, email: 'refund-cashier@example.test', password: 'password123', role: 'cashier', name: 'Casey Cashier')
    @location = Location.create!(source: 'ctrax', externalId: 'staff-controls/refund', name: 'Refund fixture')
    @checkout = paid_card_checkout(@cashier, total_cents: 48_000)
    @manager = manager_with_pin(pin: '4321')
    sign_in @cashier
  end
  teardown { Current.reset }

  test 'a cashier refund with no manager approval is refused and nothing reaches the gateway' do
    Pos::CardReversal.expects(:call).never

    post reverse_pos_checkout_path(@checkout), params: { amount: '480.00', reason: 'Customer returned it' }

    assert_redirected_to pos_checkout_path(@checkout)
    assert_match(/manager must approve this refund/, flash[:alert])
    assert_empty PosCardReversal.all
  end

  test 'a wrong manager PIN is refused and logged; five wrong PINs lock that manager out' do
    Pos::CardReversal.expects(:call).never

    5.times do
      post reverse_pos_checkout_path(@checkout), params: refund_params(pin: '0000')
      assert_equal 'That PIN is not right.', flash[:alert]
    end
    post reverse_pos_checkout_path(@checkout), params: refund_params(pin: '4321')
    assert_match(/Too many wrong PINs/, flash[:alert])

    event = ComplianceEvent.where(action: 'override_refused').first
    assert_equal [@cashier.id, @manager.id, @checkout.id], [event.user_id, event.approver_id, event.pos_checkout_id]
    assert_equal({ 'source' => 'refund', 'amount_cents' => 48_000, 'refusal' => 'wrong_pin' }, event.details)
    assert_empty ComplianceEvent.where(action: 'override_granted')
  end

  test 'a short reason, or a person who cannot approve overrides, is refused' do
    Pos::CardReversal.expects(:call).never

    post reverse_pos_checkout_path(@checkout), params: refund_params(reason: 'Return')
    assert_match(/reason of at least 8 characters/, flash[:alert])
    post reverse_pos_checkout_path(@checkout), params: refund_params(user: @cashier)
    assert_equal 'Choose a manager who can approve overrides.', flash[:alert]
  end

  test 'a cashier refund with the manager PIN goes through and the approval is logged' do
    reversal = PosCardReversal.new(kind: 'refund', status: 'succeeded', amount_cents: 48_000)
    Pos::CardReversal.expects(:call).with(checkout: @checkout, amount_cents: 48_000, reason: 'Customer returned it', user: @cashier).returns(reversal)

    get pos_checkout_path(@checkout)
    assert_select "form[action='#{reverse_pos_checkout_path(@checkout)}'] [data-refund-approval]" do
      assert_select 'select[name=override_user_id] option', text: @manager.display_name
      assert_select 'input[name=override_pin][type=password]'
    end
    post reverse_pos_checkout_path(@checkout), params: refund_params

    assert_equal 'Refunded 480.00 USD on the original card.', flash[:notice]
    event = ComplianceEvent.last
    assert_equal ['override_granted', @cashier.id, @manager.id, @checkout.id, 'Customer returned it'],
      [event.action, event.user_id, event.approver_id, event.pos_checkout_id, event.reason]
    delete logout_path
    sign_in users(:regular_user)
    get compliance_path(tab: 'audit')
    assert_select 'tr[data-compliance-action=override_granted]', 1
  end

  test 'an owner refunds without a PIN, as before' do
    delete logout_path
    sign_in users(:regular_user)
    reversal = PosCardReversal.new(kind: 'refund', status: 'succeeded', amount_cents: 500)
    Pos::CardReversal.expects(:call).with(checkout: @checkout, amount_cents: 500, reason: 'Returned', user: users(:regular_user)).returns(reversal)

    get pos_checkout_path(@checkout)
    assert_select '[data-refund-approval]', false
    post reverse_pos_checkout_path(@checkout), params: { amount: '5.00', reason: 'Returned' }

    assert_equal 'Refunded 5.00 USD on the original card.', flash[:notice]
    assert_empty ComplianceEvent.all
  end

  test 'a cashier cannot refund a sale another cashier rang' do
    other = User.create!(tenant: Current.tenant, email: 'refund-other@example.test', password: 'password123', role: 'cashier')
    theirs = paid_card_checkout(other, total_cents: 2000)
    Pos::CardReversal.expects(:call).never

    post reverse_pos_checkout_path(theirs), params: { amount: '20.00', reason: 'Customer returned it' }

    assert_response :not_found
  end

  private

  def refund_params(pin: '4321', reason: 'Customer returned it', user: @manager)
    { amount: '480.00', reason: reason, override_user_id: user.id, override_pin: pin }
  end

  def paid_card_checkout(user, total_cents:)
    display = PosDisplaySession.create!(user: user, location: @location)
    register = Sales::PosSession.create!(location: @location, user: user, name: "Front #{user.id}", opened_at: Time.current)
    checkout = PosCheckout.create!(location: @location, user: user, pos_display_session: display, pos_session: register, cart_revision: 1,
      reference: SecureRandom.hex(16), tender: 'card', status: 'paid', paid_at: Time.current,
      lines_json: [{ 'title' => 'Sample item', 'quantity' => 1, 'unit_price' => format('%.2f', total_cents / 100.0) }],
      subtotal_cents: total_cents, tax_cents: 0, tip_cents: 0, total_cents: total_cents, gateway_id: '123', environment: 'production')
    checkout.pos_payment_attempts.create!(invoice: "RP#{SecureRandom.hex(4)}", nonce_digest: SecureRandom.hex(32), submitted_at: Time.current, status: 'paid',
      transaction_id: SecureRandom.random_number(10**6).to_s, card_brand: 'Visa', card_last_four: '4242', auth_code: 'AB12CD')
    checkout
  end
end
