# frozen_string_literal: true

require 'test_helper'
require_relative '../support/compliance_fixtures'

# F70 event mode: open after the checklist, sell only the frozen list, record each
# sale once (replay and offline safe), close with reconciliation.
class PosEventSaleRecorderTest < ActiveSupport::TestCase
  include ComplianceFixtures

  CHECKLIST = PosEvent::CHECKLIST.keys.index_with { '1' }.freeze

  setup do
    Current.tenant = tenants(:default_tenant)
    Finance::ChartOfAccounts.seed!
    @location = compliance_store
    @seller = cashier
    @manager = manager_with_pin
    Current.user = @manager
    @tincture = approve!(@location, '11', name: 'Broad Spectrum Hemp Extract 1000mg', category: card_category, receipt_name: 'Hemp Extract 1000mg')
    @flower = approve!(@location, '22', name: 'Hemp Flower 3.5g', category: cash_category, card: false)
    @event = PosEvent.create!(location: @location, name: 'Wellness Fair', starts_on: Date.current, ends_on: Date.current, tax_rate_bps: 600,
      opening_float_cents: 10_000, staff_user_ids_json: [@seller.id])
    @extract = @event.pos_event_items.create!(compliance_catalog_item: @tincture, name: 'x', price_cents: 3500, loaded_quantity: 10)
    @bud = @event.pos_event_items.create!(compliance_catalog_item: @flower, name: 'x', price_cents: 2500, loaded_quantity: 10)
  end
  teardown { Current.reset }

  test 'opening needs every checklist item, then freezes names, card eligibility and COA links' do
    error = assert_raises(Pos::Error) { Pos::EventWorkflow.open!(@event, user: @manager, checklist: CHECKLIST.except('staff_briefed')) }
    assert_match(/check ID/, error.message)
    assert @event.reload.draft?
    open!
    assert_equal ['Hemp Extract 1000mg', true], [@extract.reload.name, @extract.card_eligible]
    assert_match %r{\Ahttps://labs\.example\.com/coa/}, @extract.coa_url
    assert_equal ['Hemp Flower 3.5g', false], [@bud.reload.name, @bud.card_eligible]
    assert_equal 'event_opened', ComplianceEvent.last.action
  end

  test 'card eligibility is frozen off when the item has no current COA' do
    @tincture.certificates_of_analysis.destroy_all
    open!
    assert_not @extract.reload.card_eligible
  end

  test 'an item that is no longer approved stops the event opening' do
    @flower.update!(status: 'suspended')
    error = assert_raises(Pos::Error) { open! }
    assert_match(/suspended/, error.message)
  end

  test 'a cash sale is server-priced with event tax, creates one canonical order and is idempotent' do
    open!
    lines = [{ event_item_id: @extract.id, quantity: 2 }, { event_item_id: @bud.id, quantity: 1 }]
    assert_raises(Pos::Error) { record(tender: 'cash', cash_received: '100', lines: lines) }
    sale = record(tender: 'cash', cash_received: '101', lines: lines)
    assert_equal [9500, 570, 10_070, 30], [sale.subtotal_cents, sale.tax_cents, sale.total_cents, sale.change_cents]

    sale = record(tender: 'cash', cash_received: '110', client_sale_id: 'sale-two-0001', lines: [{ event_item_id: @extract.id, quantity: 2 }, { event_item_id: @bud.id, quantity: 1 }])
    assert_equal 930, sale.change_cents
    again = record(tender: 'cash', cash_received: '110', client_sale_id: 'sale-two-0001', lines: [{ event_item_id: @extract.id, quantity: 9 }])
    assert_equal sale.id, again.id
    order = sale.order
    assert_equal ['rupert_pos', 'pos', @location.externalId, 10_070, 570], [order.source, order.channel, order.location_id, order.gross_cents, order.tax_cents]
    assert_equal ['Hemp Extract 1000mg', 'Hemp Flower 3.5g'], order.order_lines.order(:id).pluck(:name)
    assert_equal ['cash', 10_070], order.payments.sole.then { |p| [p.method, p.amount_cents] }
    assert_equal 2, @event.pos_event_sales.count
    assert_equal 2, Core::Order.where(source: 'rupert_pos').count
  end

  test 'card on a cash-only item is refused until a manager overrides; staff list and ID are enforced' do
    open!
    error = assert_raises(Compliance::Blocked) { record(tender: 'card_terminal', lines: [{ event_item_id: @bud.id, quantity: 1 }]) }
    assert_match(/cash only/, error.message)
    assert_equal 'sale_blocked', ComplianceEvent.last.action
    assert_raises(Compliance::Blocked) { record(tender: 'cash', cash_received: '30', id_checked: '0') }
    stranger = cashier
    assert_raises(Pos::Error) { record(user: stranger, tender: 'cash', cash_received: '50') }

    sale = record(tender: 'card_terminal', lines: [{ event_item_id: @bud.id, quantity: 1 }],
      override_user_id: @manager.id.to_s, override_pin: '4321', override_reason: 'Owner approved card for this sale')
    assert_equal [@manager.id, 'card_terminal'], [sale.override_by_id, sale.tender]
    assert_equal 'card', sale.order.payments.sole.method
    assert_equal %w[override_granted event_sale], ComplianceEvent.where(pos_event_id: @event.id).order(:id).pluck(:action).last(2)
  end

  test 'a pulled item stops selling; an offline sale made before the pull is recorded and flagged' do
    open!
    sold_at = 2.minutes.ago
    Pos::EventWorkflow.pull!(@event, @extract, user: @manager, reason: 'Batch label misprinted')
    assert_raises(Pos::Error) { record(tender: 'cash', cash_received: '50') }
    sale = record(tender: 'cash', cash_received: '50', offline: 'true', occurred_at: sold_at.iso8601)
    assert_includes sale.flags, 'pulled_item'
    assert_equal sold_at.to_i, sale.occurred_at.to_i
  end

  test 'an offline sale whose item was suspended after it sold is kept and flagged, not lost' do
    open!
    @tincture.update!(status: 'suspended')
    assert_raises(Compliance::Blocked) { record(tender: 'cash', cash_received: '50') }
    sale = record(tender: 'cash', cash_received: '50', offline: 'true', occurred_at: 1.minute.ago.iso8601, client_sale_id: 'offline-0001')
    assert_equal ['suspended'], sale.flags
    assert_equal 'event_sale_flagged', ComplianceEvent.last.action
    assert_raises(Pos::Error) { record(tender: 'cash', cash_received: '50', offline: 'true', occurred_at: 2.days.from_now.iso8601, client_sale_id: 'offline-0002') }
  end

  test 'closing reconciles cash, card and counted units, and stops sales' do
    open!
    record(tender: 'cash', cash_received: '40', lines: [{ event_item_id: @extract.id, quantity: 1 }])
    record(tender: 'card_terminal', client_sale_id: 'card-sale-001', lines: [{ event_item_id: @extract.id, quantity: 2 }])
    Pos::EventWorkflow.close!(@event, user: @manager, counted_cash_cents: 13_600, terminal_card_total_cents: 7420,
      counted: { @extract.id.to_s => '7', @bud.id.to_s => '' }, notes: 'Short one dollar')
    @event.reload
    assert @event.closed?
    assert_equal [13_710, -110, 0], [@event.expected_cash_cents, @event.cash_variance_cents, @event.card_variance_cents]
    assert_equal({ @extract.id => 3 }, @event.units_sold)
    assert_equal [7, nil], [@extract.reload.counted_remaining, @bud.reload.counted_remaining]
    assert_raises(Pos::Error) { record(tender: 'cash', cash_received: '40', client_sale_id: 'after-close-1') }
  end

  test 'events, items and sales are workspace scoped' do
    open!
    sale = record(tender: 'cash', cash_received: '40')
    other = create_workspace('Other store', current: false)
    Current.set(tenant: other) do
      assert_nil PosEvent.find_by(id: @event.id)
      assert_nil PosEventSale.find_by(id: sale.id)
      assert_nil ComplianceCatalogItem.find_by(id: @tincture.id)
    end
  end

  private

  def open! = Pos::EventWorkflow.open!(@event, user: @manager, checklist: CHECKLIST)

  def record(user: @seller, client_sale_id: "sale-#{SecureRandom.hex(6)}", id_checked: '1', lines: [{ event_item_id: @extract.id, quantity: 1 }], **params)
    payload = ActionController::Parameters.new({ client_sale_id: client_sale_id, id_checked: id_checked, lines: lines }.merge(params))
    Pos::EventSaleRecorder.record!(event: @event.reload, user: user, params: payload)
  end
end
