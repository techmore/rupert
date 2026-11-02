# frozen_string_literal: true

require 'test_helper'
require_relative '../support/compliance_fixtures'

# F70 on the C-Trax register: a locked store sells approved items only, under
# compliant names, after the pre-sale check (or a manager override).
class PosCheckoutComplianceTest < ActiveSupport::TestCase
  include ComplianceFixtures

  setup do
    Current.tenant = tenants(:default_tenant)
    @location = compliance_store
    @snapshot = CtraxStockSnapshot.find_by!(location: @location)
    @cashier = cashier
    Current.user = @cashier
    @manager = manager_with_pin
    @tincture = approve!(@location, '11', name: 'Broad Spectrum Hemp Extract 1000mg', category: card_category, receipt_name: 'Hemp Extract 1000mg')
    @flower = approve!(@location, '22', name: 'Hemp Flower 3.5g', category: cash_category, card: false)
    CompliancePolicy.create!(location: @location, locked_catalog: true)
    PosConnection.create!(provider: 'ctrax', vendor_approved: true, credentials_json: { api_url: 'https://fixture.api.cannatrax.net', api_username: 'f', api_password: 'p' }.to_json)
    PosSetting.create!(location: @location, cash_enabled: true)
    @register = Sales::PosSession.create!(location: @location, user: @cashier, name: 'Front', opened_at: Time.current, opening_cash_cents: 0)
    Ctrax::StockSync.stubs(:call).returns(stores: 1, variants: 1)
  end
  teardown { Current.reset }

  test 'cash sale of approved items needs the ID check and records compliant names on the order' do
    display = confirmed_display({ '11' => 1, '22' => 1 })
    error = assert_raises(Compliance::Blocked) { prepare(display, 'cash') }
    assert_equal [:id_not_checked], error.result.blocking.map(&:code)
    checkout = prepare(display, 'cash', id_checked: '1')
    assert checkout.id_checked
    Pos::Checkout.cash!(checkout, received: '100.00')
    names = checkout.reload.order.order_lines.order(:id).pluck(:name)
    assert_equal ['Hemp Extract 1000mg', 'Hemp Flower 3.5g'], names
    assert_equal %w[sale_blocked], ComplianceEvent.pluck(:action)
  end

  test 'A920 card on a cash-only item is blocked, then completes with a manager PIN override, once' do
    display = confirmed_display({ '22' => 1 })
    error = assert_raises(Compliance::Blocked) { prepare(display, 'card_a920', id_checked: '1') }
    assert error.result.overridable?
    assert_empty PosCheckout.all

    override = { id_checked: '1', override_user_id: @manager.id.to_s, override_pin: '4321', override_reason: 'Owner approved card for this regular' }
    checkout = prepare(display, 'card_a920', **override)
    Pos::Checkout.terminal_card!(checkout)
    checkout.reload
    assert checkout.paid?
    assert_equal [@manager.id, 'Owner approved card for this regular'], [checkout.compliance_override_by_id, checkout.compliance_override_reason]
    assert_equal ['card_ineligible'], checkout.compliance_issues.select { |i| i['severity'] == 'block' }.map { |i| i['code'] }
    # Replay returns the same checkout without a second override.
    assert_equal checkout.id, prepare(display, 'card_a920', **override).id
    assert_equal %w[sale_blocked override_granted], ComplianceEvent.order(:id).pluck(:action)
  end

  test 'an item off the approved list cannot be checked out even if it reached the cart' do
    display = confirmed_display({ '33' => 1 })
    Ctrax::StockSync.unstub(:call)
    Ctrax::StockSync.expects(:call).never # a blocked cart never reaches the source stock read
    error = assert_raises(Compliance::Blocked) { prepare(display, 'cash', id_checked: '1', override_user_id: @manager.id.to_s, override_pin: '4321', override_reason: 'Trying to sell anyway') }
    assert_kind_of Compliance::OverrideRefused, error
    assert_empty PosCheckout.all
  end

  test 'a suspended item stops ringing up at once' do
    @tincture.update!(status: 'suspended')
    display = confirmed_display({ '11' => 1 })
    assert_raises(Compliance::Blocked) { prepare(display, 'cash', id_checked: '1') }
  end

  test 'an unlocked store keeps the existing checkout unchanged' do
    CompliancePolicy.find_by!(location: @location).update!(locked_catalog: false)
    display = confirmed_display({ '33' => 1 })
    checkout = prepare(display, 'cash')
    assert_nil checkout.id_checked
    assert_nil checkout.compliance_issues_json
    assert_empty ComplianceEvent.all
  end

  test 'demo displays are never blocked' do
    display = confirmed_display({ '33' => 1 }, demo: true)
    assert prepare(display, 'cash')
  end

  private

  def prepare(display, tender, **compliance)
    Pos::Checkout.prepare!(display: display.reload, tender: tender, register_id: @register.id, compliance: compliance)
  end

  def confirmed_display(quantities, demo: false)
    display = PosDisplaySession.create!(user: @cashier, location: @location, demo: demo)
    records = @snapshot.records.index_by { |row| row['id'] }
    lines = quantities.map do |id, quantity|
      price = BigDecimal(records[id]['price_cents'].to_s) / 100
      { variant_id: id, sku: records[id]['sku'], title: records[id]['name'], product_title: records[id]['name'], quantity: quantity,
        unit_price: price.to_s('F'), line_total: (price * quantity).to_s('F') }
    end
    quote = { source: 'ctrax', currency_code: 'USD', preview: demo, subtotal: lines.sum { |l| BigDecimal(l[:line_total]) }.to_s('F'), lines: lines }
    Pos::Quote.decorate!(quote, @snapshot, demo: demo)
    display.publish!(quote.deep_stringify_keys)
    display.choose_tip!(revision: display.cart_revision, choice: 'none')
    display
  end
end
