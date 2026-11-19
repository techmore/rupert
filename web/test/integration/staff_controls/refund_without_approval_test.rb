# frozen_string_literal: true

require 'test_helper'

# Characterization: pins behaviour pending owner decision (docs/decisions/staff-controls-2026-11.md, item a).
# A cashier can refund a card sale they rang, for any amount up to the sale total, with no second person.
class StaffControlsRefundWithoutApprovalTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @cashier = User.create!(tenant: Current.tenant, email: 'refund-cashier@example.test', password: 'password123', role: 'cashier', name: 'Casey Cashier')
    @location = Location.create!(source: 'ctrax', externalId: 'staff-controls/refund', name: 'Refund fixture')
    @checkout = paid_card_checkout(@cashier, total_cents: 48_000)
    sign_in @cashier
  end
  teardown { Current.reset }

  test 'a cashier refunds the whole of their own card sale with no approval' do
    reversal = PosCardReversal.new(kind: 'refund', status: 'succeeded', amount_cents: 48_000)
    Pos::CardReversal.expects(:call).with(checkout: @checkout, amount_cents: 48_000, reason: 'Customer returned it', user: @cashier).returns(reversal)

    get pos_checkout_path(@checkout)
    assert_select "form[action='#{reverse_pos_checkout_path(@checkout)}']"
    assert_select "form[action='#{reverse_pos_checkout_path(@checkout)}'] [name=override_pin]", false
    post reverse_pos_checkout_path(@checkout), params: { amount: '480.00', reason: 'Customer returned it' }

    assert_redirected_to pos_checkout_path(@checkout)
    assert_equal 'Refunded 480.00 USD on the original card.', flash[:notice]
  end

  test 'a cashier cannot refund a sale another cashier rang' do
    other = User.create!(tenant: Current.tenant, email: 'refund-other@example.test', password: 'password123', role: 'cashier')
    theirs = paid_card_checkout(other, total_cents: 2000)
    Pos::CardReversal.expects(:call).never

    post reverse_pos_checkout_path(theirs), params: { amount: '20.00', reason: 'Customer returned it' }

    assert_response :not_found
  end

  private

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
