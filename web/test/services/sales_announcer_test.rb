# frozen_string_literal: true

require "test_helper"

class SalesAnnouncerTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
  end

  teardown do
    Setting.where(key: SalesAnnouncer::WATERMARK_KEY).delete_all
    LedgerEntry.where(tenant_id: Current.tenant_id).delete_all
    Current.tenant = nil
  end

  def make_entry(occurred_at, gross:, source: "square", status: "COMPLETED", summary: "Honey Sticks")
    attrs = {
      source: source,
      sourceOrderId: SecureRandom.hex(8),
      orderName: "SQ-test",
      occurredAt: occurred_at,
      syncedAt: Time.current,
      currency: "USD",
      grossCents: gross,
      status: status,
      lineItems: 1,
      summary: summary,
      tenant_id: Current.tenant_id,
    }
    LedgerEntry.create!({ id: "square:#{SecureRandom.hex(8)}" }.merge(attrs))
  end

  def announce!
    BuzzAgent.stubs(:configured?).returns(true)
    BuzzAgent.stubs(:notify).returns([true, "OK"])
    SalesAnnouncer.announce!
  end

  test "first run establishes a baseline and announces nothing" do
    old = make_entry(3.days.ago, gross: 1000)
    assert_equal 0, announce!
    assert_equal old.occurredAt.utc.iso8601(6), Setting.find_by(key: SalesAnnouncer::WATERMARK_KEY).value
  end

  test "announces new sales after the baseline and advances the watermark" do
    make_entry(3.days.ago, gross: 1000)
    announce!
    new = make_entry(1.hour.ago, gross: 2500)

    capture = nil
    BuzzAgent.stubs(:notify).with do |content, *_|
      capture = content
      true
    end.returns([true, "OK"])
    count = announce!

    assert_equal 1, count
    assert_includes capture, "Honey Sticks"
    assert_equal new.occurredAt.utc.iso8601(6), Setting.find_by(key: SalesAnnouncer::WATERMARK_KEY).value
  end

  test "posts item and amount for each new sale" do
    make_entry(3.days.ago, gross: 1000)
    announce!
    make_entry(1.hour.ago, gross: 2500, summary: "THCA Pre-Roll")

    capture = nil
    BuzzAgent.stubs(:notify).with do |content, *_|
      capture = content
      true
    end.returns([true, "OK"])
    announce!

    assert_includes capture, "THCA Pre-Roll"
    assert_includes capture, "$25.00"
  end

  test "ignores non-revenue statuses" do
    make_entry(3.days.ago, gross: 1000)
    announce!
    make_entry(1.hour.ago, gross: 2500, status: "CANCELED")

    BuzzAgent.expects(:notify).never
    assert_equal 0, announce!
  end

  test "no-ops when Buzz is not configured" do
    BuzzAgent.stubs(:configured?).returns(false)
    assert_equal 0, SalesAnnouncer.announce!
  end
end
