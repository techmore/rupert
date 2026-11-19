# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/compliance_fixtures'

# Characterization: pins behaviour pending owner decision (docs/decisions/staff-controls-2026-11.md, item c).
# An event sale sent with `offline: true` and a time the device supplies is recorded and flagged
# even when the item was already blocked at that time. Rupert does not check that the block came
# after the sale; it trusts the device's word for when the sale happened.
class StaffControlsEventOfflineFlagTest < ActiveSupport::TestCase
  include ComplianceFixtures

  setup do
    Current.tenant = tenants(:default_tenant)
    Finance::ChartOfAccounts.seed!
    @location = compliance_store
    @seller = cashier
    @manager = manager_with_pin
    Current.user = @manager
    @tincture = approve!(@location, '11', name: 'Broad Spectrum Hemp Extract 1000mg', category: card_category, receipt_name: 'Hemp Extract 1000mg')
    @event = PosEvent.create!(location: @location, name: 'Wellness Fair', starts_on: Date.current, ends_on: Date.current, tax_rate_bps: 600,
      opening_float_cents: 10_000, staff_user_ids_json: [@seller.id])
    @extract = @event.pos_event_items.create!(compliance_catalog_item: @tincture, name: 'x', price_cents: 3500, loaded_quantity: 10)
    travel_to 2.hours.ago do
      Pos::EventWorkflow.open!(@event, user: @manager, checklist: PosEvent::CHECKLIST.keys.index_with { '1' })
    end
    travel_to(1.hour.ago) { @tincture.update!(status: 'suspended') }
  end
  teardown { Current.reset }

  test 'an item suspended an hour ago is refused online' do
    assert_raises(Compliance::Blocked) { record }
    assert_empty PosEventSale.all
  end

  test 'the same sale marked offline and timed after the suspension is recorded and flagged' do
    sale = record(offline: 'true', occurred_at: 5.minutes.ago.iso8601)

    assert_equal ['suspended'], sale.flags
    assert_equal 3710, sale.total_cents
    assert_equal 'event_sale_flagged', ComplianceEvent.last.action
    assert sale.order.paid?
  end

  private

  def record(**params)
    payload = ActionController::Parameters.new({ client_sale_id: "sale-#{SecureRandom.hex(6)}", id_checked: '1', tender: 'cash', cash_received: '50',
      lines: [{ event_item_id: @extract.id, quantity: 1 }] }.merge(params))
    Pos::EventSaleRecorder.record!(event: @event.reload, user: @seller, params: payload)
  end
end
