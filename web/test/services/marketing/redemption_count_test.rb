# frozen_string_literal: true

require 'test_helper'

# Counting a marketing event's code redemptions from Rupert's stored orders (#415): read-only towards orders and every
# outside system, split by order source and currency, limited to the event's window and store, and never counting an
# order for two events or mixing hand-entered and counted figures for one code.
class MarketingRedemptionCountTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = users(:regular_user)
    Current.user = @admin
    FeatureFlag.set(:marketing, true)
    @campaign = Marketing::Campaign.create!(name: 'Market season', storefront_url: 'https://shop.example.com', topics: 'tea')
    @event = event('Saturday market', starts: '2026-11-07T09:00', ends: '2026-11-07T14:00')
  end

  teardown { Current.reset }

  def event(title, starts:, ends:, **details)
    Work::Item.create!(kind: 'marketing_event', title: title, source: @campaign,
      details: { 'starts_at' => starts, 'ends_at' => ends, 'time_zone' => 'Eastern Time (US & Canada)', 'channel' => 'market' }.merge(details))
  end

  def order(at:, codes:, cents: 2000, tax: 100, source: 'shopify', currency: 'USD', status: 'paid', location: nil, tenant: @tenant)
    row = Core::Order.unscoped.create!(tenant_id: tenant.id, source: source, source_order_id: SecureRandom.hex(6), occurred_at: Time.zone.parse(at),
      gross_cents: cents, tax_cents: tax, currency: currency, discount_codes: codes, location_id: location)
    row.update_columns(status: status)
    row
  end

  test 'counts orders that used the code inside the event window, by source and currency, without changing them' do
    hit = order(at: '2026-11-07 10:00', codes: ['market10'])
    order(at: '2026-11-07 11:00', codes: %w[OTHER Market10], cents: 3000, tax: 0, source: 'square')
    order(at: '2026-11-07 12:00', codes: ['MARKET10'], cents: 5000, tax: 0, currency: 'CAD')
    order(at: '2026-11-07 15:00', codes: ['MARKET10'])                    # after the event
    order(at: '2026-11-07 10:30', codes: ['MARKET10'], status: 'cancelled')
    order(at: '2026-11-07 10:30', codes: ['MARKET100'])                   # a different code
    other = Tenant.create!(name: 'Other shop', subdomain: 'redeem-other')
    order(at: '2026-11-07 10:30', codes: ['MARKET10'], tenant: other)
    snapshot = Core::Order.unscoped.order(:id).pluck(:id, :status, :gross_cents, :updated_at)

    rows = Marketing::RedemptionCount.call(@event, actor: @admin, code: 'market10')

    assert_equal snapshot, Core::Order.unscoped.order(:id).pluck(:id, :status, :gross_cents, :updated_at), 'orders are only read'
    assert_not_requested :any, /.*/
    by_key = rows.index_by { |row| [row.order_source, row.currency] }
    assert_equal [['shopify', 'CAD'], ['shopify', 'USD'], ['square', 'USD']].sort, by_key.keys.sort
    assert_equal [1, 1900, [hit.id]], by_key[%w[shopify USD]].then { |row| [row.redemptions, row.revenue_cents, row.order_ids] }
    assert_equal 3000, by_key[%w[square USD]].revenue_cents
    assert_equal 5000, by_key[%w[shopify CAD]].revenue_cents
    assert(rows.all? { |row| row.basis == 'stored_orders' && row.code == 'MARKET10' })

    again = Marketing::RedemptionCount.call(@event, actor: @admin, code: 'MARKET10')
    assert_equal rows.map(&:id).sort, again.map(&:id).sort, 'counting again replaces, not adds'
    assert_equal 3, Marketing::Result.where(work_item_id: @event.id).count
  end

  test 'an order counted for one event is not counted for another, and the store location narrows the count' do
    location = Location.create!(source: 'shopify', externalId: 'store-main', name: 'Main St')
    order(at: '2026-11-07 10:00', codes: ['MARKET10'], location: location.externalId)
    order(at: '2026-11-07 10:05', codes: ['MARKET10'], location: 'store-elsewhere')
    Marketing::RedemptionCount.call(@event, actor: @admin, code: 'MARKET10')
    assert_equal 2, Marketing::Result.where(work_item_id: @event.id).sum(:redemptions)

    overlapping = event('Same day online push', starts: '2026-11-07T08:00', ends: '2026-11-07T20:00', 'location_id' => location.externalId)
    rows = Marketing::RedemptionCount.call(overlapping, actor: @admin, code: 'MARKET10')
    assert_empty rows, 'both orders were already counted for the market'
    assert_equal 2, Marketing::Result.sum(:redemptions)

    late = event('Later', starts: '2026-11-08T08:00', ends: '2026-11-08T20:00', 'location_id' => location.externalId)
    order(at: '2026-11-08 10:00', codes: ['MARKET10'], location: location.externalId)
    order(at: '2026-11-08 10:00', codes: ['MARKET10'], location: 'store-elsewhere')
    assert_equal 1, Marketing::RedemptionCount.call(late, actor: @admin, code: 'MARKET10').sum(&:redemptions)
  end

  test 'hand-entered results and counted results never mix for one code, and figures are checked' do
    manual = Marketing::Result.create!(work_item_id: @event.id, code: 'MARKET10', basis: 'manual', redemptions: 12, revenue_cents: 24_000)
    order(at: '2026-11-07 10:00', codes: ['MARKET10'])
    error = assert_raises(ActiveRecord::RecordInvalid) { Marketing::RedemptionCount.call(@event, actor: @admin, code: 'MARKET10') }
    assert_match(/entered by hand/, error.message)
    manual.destroy!
    Marketing::RedemptionCount.call(@event, actor: @admin, code: 'MARKET10')
    refute Marketing::Result.new(work_item_id: @event.id, code: 'MARKET10', basis: 'manual', redemptions: 1).valid?

    bad = Marketing::Result.new(work_item_id: @event.id, code: 'flyer', basis: 'manual', redemptions: -1, revenue_cents: 5, currency: 'dollars')
    refute bad.valid?
    assert bad.errors[:redemptions].any?
    assert bad.errors[:currency].any?
    task = Projects::Task.create!(title: 'Not an event')
    refute Marketing::Result.new(work_item_id: task.id, basis: 'manual', redemptions: 1).valid?
  end

  test 'refuses a missing code or a bad window' do
    assert_raises(Marketing::RedemptionCount::Refused) { Marketing::RedemptionCount.call(@event, actor: @admin, code: '') }
    assert_raises(Marketing::RedemptionCount::Refused) do
      Marketing::RedemptionCount.call(@event, actor: @admin, code: 'MARKET10', from: Time.current, to: 1.hour.ago)
    end
  end
end
