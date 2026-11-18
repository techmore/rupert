# frozen_string_literal: true

require 'test_helper'
require_relative '../support/dejavoo_spin_fixture'

# The terminal's entry type becomes one short word on the payment attempt and, for a
# live sale, on the order's payment. The terminal's own wording is never stored.
class DejavooEntryMethodTest < ActiveSupport::TestCase
  include DejavooSpinFixture

  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @location = Location.create!(source: 'ctrax', externalId: 'dejavoo-entry/1', name: 'Dejavoo entry method store')
    @display = PosDisplaySession.create!(user: @user, location: @location)
    @register = Sales::PosSession.create!(location: @location, user: @user, name: 'Sandbox', opened_at: Time.current)
    @setting = PosSetting.create!(location: @location, gateway_provider: 'dejavoo_spin', environment: 'sandbox', credentials_json: dejavoo_credentials)
    @setting.update!(verified_at: Time.current)
    @setting.update!(card_enabled: true)
    @gateway = Pos::DejavooSpinGateway.new(@setting)
    prepare_dejavoo_fixture
  end
  teardown { Current.reset }

  def checkout!(environment: 'sandbox')
    @revision = @revision.to_i + 1
    PosCheckout.create!(location: @location, user: @user, pos_display_session: @display, pos_session: @register,
      cart_revision: @revision, reference: SecureRandom.hex(16), tender: 'card', gateway_provider: 'dejavoo_spin',
      gateway_fingerprint: @setting.payment_fingerprint, environment: environment,
      lines_json: [{ 'variant_id' => '7', 'sku' => 'HH-CBD-1', 'category' => 'CBD Isolate', 'title' => 'CBD tincture', 'quantity' => 1, 'unit_price' => '10.05', 'line_total' => '10.05' }],
      subtotal_cents: 1005, tax_cents: 60, tip_cents: 101, total_cents: 1166)
  end

  def sale = @gateway.sale(reference: Pos::DejavooSpinGateway.reference, amount_cents: 1166)

  test 'each entry type the terminal can report maps to one word' do
    { 'Contactless' => 'tap', 'ChipContactless' => 'tap', 'Chip' => 'chip', 'Swipe' => 'swipe', 'Manual' => 'keyed' }.each do |reported, word|
      @spin_entry_type = reported
      result = sale
      assert_equal [reported, word], [result.entry_type, result.entry_method]
    end
    assert_equal Pos::DejavooSpinGateway::ENTRY_TYPES.sort, Pos::DejavooSpinGateway::ENTRY_METHODS.keys.sort, 'every whitelisted entry type has a word'
    assert_empty Pos::DejavooSpinGateway::ENTRY_METHODS.values - PaymentEntryMethod::VALUES
  end

  test 'a missing, unlisted or malformed entry type is unknown and its text is dropped' do
    [nil, '', 'contactless', 'Fallback', 'Contactless 4111111111111111', 4, { 'Type' => 'Chip' }].each do |reported|
      @spin_entry_type = reported
      result = sale
      assert result.approved?, reported.inspect
      assert_nil result.entry_type, reported.inspect
      assert_equal 'unknown', result.entry_method, reported.inspect
    end
  end

  test 'an approved terminal sale stores tap on the attempt and shows it on the receipt' do
    checkout = checkout!
    Pos::DejavooTerminalPayment.call(checkout)
    assert checkout.reload.paid?
    attempt = checkout.pos_payment_attempts.sole
    assert_equal 'tap', attempt.entry_method
    assert_equal 'tap', checkout.receipt[:card][:entry_method]
    assert_not_includes attempt.attributes.to_json, 'Contactless'
  end

  test 'an approved sale with no usable entry type is still paid and stores unknown' do
    [nil, 'Fallback 4111111111111111'].each do |reported|
      @spin_entry_type = reported
      checkout = checkout!
      Pos::DejavooTerminalPayment.call(checkout)
      assert checkout.reload.paid?, reported.inspect
      attempt = checkout.pos_payment_attempts.sole
      assert_equal %w[paid unknown], [attempt.status, attempt.entry_method]
      assert_not_includes attempt.attributes.to_json, 'Fallback'
    end
  end

  test 'a declined sale records no entry method' do
    @spin_sale_mode = :declined
    checkout = checkout!
    Pos::DejavooTerminalPayment.call(checkout)
    assert_equal 'declined', checkout.reload.status
    assert_nil checkout.pos_payment_attempts.sole.entry_method
  end

  test 'a live sale carries the entry method to the order payment; other tenders leave it empty' do
    live = checkout!(environment: 'production')
    live.with_lock { Pos::Checkout.finalize!(live, transaction_id: '987654321', entry_method: 'chip') }
    assert_equal ['card', 1166, 'chip'], live.reload.order.payments.sole.values_at(:method, :amount_cents, :entry_method)

    plain = checkout!(environment: 'production')
    plain.with_lock { Pos::Checkout.finalize!(plain, transaction_id: '987654322') }
    assert_nil plain.reload.order.payments.sole.entry_method
  end
end
