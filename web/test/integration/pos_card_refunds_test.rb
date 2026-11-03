# frozen_string_literal: true

require 'test_helper'

class PosCardRefundsIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @location = Location.create!(source: 'ctrax', externalId: 'refund-ui/1', name: 'Refund UI')
    display = PosDisplaySession.create!(user: @user, location: @location)
    register = Sales::PosSession.create!(location: @location, user: @user, name: 'Front', opened_at: Time.current)
    @checkout = PosCheckout.create!(location: @location, user: @user, pos_display_session: display, pos_session: register, cart_revision: 1,
      reference: SecureRandom.hex(16), tender: 'card', status: 'paid', paid_at: Time.current, lines_json: [{ 'title' => 'CBD tincture', 'quantity' => 1, 'unit_price' => '20.00' }],
      subtotal_cents: 2000, tax_cents: 0, tip_cents: 0, total_cents: 2000, gateway_id: '123', environment: 'production')
    @checkout.pos_payment_attempts.create!(invoice: 'RPui1', nonce_digest: 'e' * 64, submitted_at: Time.current, status: 'paid',
      transaction_id: '900', card_brand: 'Visa', card_last_four: '4242', auth_code: 'AB12CD')
    post login_path, params: { email: @user.email, password: 'password' }
  end
  teardown { Current.reset }

  test 'receipt shows card details and a refund form; refund outcome is reported' do
    get pos_checkout_path(@checkout)
    assert_response :success
    assert_select 'section[aria-label="Card payment"]', /Visa ending 4242/
    assert_select 'section[aria-label="Card payment"]', /AB12CD/
    assert_select "form[action='#{reverse_pos_checkout_path(@checkout)}'] input[name=amount][value='20.00']"

    reversal = PosCardReversal.new(kind: 'refund', status: 'succeeded', amount_cents: 500)
    Pos::CardReversal.expects(:call).with(checkout: @checkout, amount_cents: 500, reason: 'Returned', user: @user).returns(reversal)
    post reverse_pos_checkout_path(@checkout), params: { amount: '5.00', reason: 'Returned' }
    assert_redirected_to pos_checkout_path(@checkout)
    assert_equal 'Refunded 5.00 USD on the original card.', flash[:notice]

    Pos::CardReversal.expects(:call).raises(Pos::Error, 'Only the whole sale can be voided today.')
    post reverse_pos_checkout_path(@checkout), params: { amount: '5.00', reason: 'Returned' }
    assert_equal 'Only the whole sale can be voided today.', flash[:alert]
  end

  test 'users without sales write cannot refund' do
    @user.update!(role: 'employee')
    Pos::CardReversal.expects(:call).never
    post reverse_pos_checkout_path(@checkout), params: { amount: '5.00', reason: 'Returned' }
    refute_match(/Refunded/, flash[:notice].to_s)
    assert_empty PosCardReversal.all
  end
end
