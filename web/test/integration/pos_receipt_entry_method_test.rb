# frozen_string_literal: true

require 'test_helper'

# The card receipt names how the card was presented, beside the brand and last four,
# when that was recorded, and says nothing when it was not.
class PosReceiptEntryMethodTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @location = Location.create!(source: 'ctrax', externalId: 'receipt-entry/1', name: 'Receipt entry method')
    display = PosDisplaySession.create!(user: @user, location: @location)
    register = Sales::PosSession.create!(location: @location, user: @user, name: 'Front', opened_at: Time.current)
    @checkout = PosCheckout.create!(location: @location, user: @user, pos_display_session: display, pos_session: register, cart_revision: 1,
      reference: SecureRandom.hex(16), tender: 'card', status: 'paid', paid_at: Time.current, lines_json: [{ 'title' => 'CBD tincture', 'quantity' => 1, 'unit_price' => '20.00' }],
      subtotal_cents: 2000, tax_cents: 0, tip_cents: 0, total_cents: 2000, gateway_id: '123', environment: 'production')
    @attempt = @checkout.pos_payment_attempts.create!(invoice: 'RPentry1', nonce_digest: 'f' * 64, submitted_at: Time.current, status: 'paid',
      transaction_id: '900', card_brand: 'Visa', card_last_four: '4242', auth_code: 'AB12CD')
    post login_path, params: { email: @user.email, password: 'password' }
  end
  teardown { Current.reset }

  def card_line
    get pos_checkout_path(@checkout)
    assert_response :success
    css_select('section[aria-label="Card payment"] dt').find { |dt| dt.text == 'Card' }.next_element.text.squish
  end

  test 'a recorded entry method is printed beside the card brand and last four' do
    { 'tap' => 'Contactless', 'chip' => 'Chip', 'swipe' => 'Swipe', 'keyed' => 'Keyed' }.each do |word, label|
      @attempt.update!(entry_method: word)
      assert_equal "Visa ending 4242 · #{label}", card_line
    end
  end

  test 'with no entry method, or an unknown one, the card line is unchanged' do
    assert_equal 'Visa ending 4242', card_line
    @attempt.update!(entry_method: 'unknown')
    assert_equal 'Visa ending 4242', card_line
  end

  test 'the entry method still prints when the brand and last four are missing' do
    @attempt.update!(card_brand: nil, card_last_four: nil, entry_method: 'tap')
    assert_equal 'Card · Contactless', card_line
  end
end
