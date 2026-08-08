# frozen_string_literal: true

require "test_helper"

class CanonicalOrderImporterTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
  end

  teardown { Current.tenant = nil }

  test "from_shopify! creates canonical orders" do
    entries = [
      {
        source: "shopify",
        sourceOrderId: "gid://shopify/Order/123",
        orderName: "#1001",
        occurredAt: Time.current,
        grossCents: 2500,
        status: "PAID",
        lineItems: 2,
      },
    ]

    count = CanonicalOrderImporter.from_shopify!(entries)
    assert_equal 1, count

    order = Core::Order.find_by(source: "shopify", source_order_id: "gid://shopify/Order/123")
    assert order
    assert_equal "online", order.channel
    assert_equal "paid", order.status
    assert_equal 2500, order.gross_cents
  end

  test "from_square! creates canonical orders" do
    entries = [
      {
        source: "square",
        sourceOrderId: "sq-abc",
        orderName: "SQ-abc",
        occurredAt: Time.current,
        grossCents: 1200,
        status: "COMPLETED",
        lineItems: 1,
      },
    ]

    CanonicalOrderImporter.from_square!(entries)
    order = Core::Order.find_by(source: "square", source_order_id: "sq-abc")
    assert order
    assert_equal "pos", order.channel
    assert_equal "paid", order.status
  end

  test "is idempotent for the same source order" do
    entry = {
      source: "shopify",
      sourceOrderId: "gid://shopify/Order/dup",
      occurredAt: Time.current,
      grossCents: 900,
      status: "PAID",
      lineItems: 1,
    }
    2.times { CanonicalOrderImporter.from_shopify!([entry]) }
    assert_equal 1, Core::Order.where(source: "shopify", source_order_id: "gid://shopify/Order/dup").count
  end

  test "backfill_from_ledger! hydrates from existing ledger entries" do
    LedgerEntry.create!(
      id: "shopify:gid://shopify/Order/ledger1",
      source: "shopify",
      sourceOrderId: "gid://shopify/Order/ledger1",
      occurredAt: Time.current,
      grossCents: 5000,
      status: "PAID",
      lineItems: 3,
      syncedAt: Time.current,
      currency: "USD",
    )

    count = CanonicalOrderImporter.backfill_from_ledger!
    assert_equal 1, count
    order = Core::Order.find_by(source_order_id: "gid://shopify/Order/ledger1")
    assert order
    assert_equal "paid", order.status
  end
end
