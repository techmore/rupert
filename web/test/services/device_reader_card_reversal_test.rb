# frozen_string_literal: true

require 'test_helper'
require_relative '../support/device_reader_fixture'

# Voids and refunds of phone card reader sales go through Pos::CardReversal,
# against the fake provider.
class DeviceReaderCardReversalTest < ActiveSupport::TestCase
  include DeviceReaderFixture
  include ActiveSupport::Testing::TimeHelpers

  Fake = Pos::DeviceReader::FakeGateway

  setup do
    Current.tenant = tenants(:default_tenant)
    prepare_device_reader_fixture(name: 'refund')
    opened = Pos::DeviceReaderPayment.open!(@checkout)
    Pos::DeviceReaderPayment.start!(opened, device_id: DEVICE)
    tap
    Pos::DeviceReaderPayment.reconcile!(opened)
    assert @checkout.reload.paid?
    @sale = @checkout.paid_attempt.invoice
  end
  teardown { Current.reset }

  def reverse(amount_cents, reason: 'Customer return') = Pos::CardReversal.call(checkout: @checkout, amount_cents: amount_cents, reason: reason, user: @user)

  test 'the whole sale is voided while the provider still allows it' do
    reversal = reverse(1166)
    assert_equal %w[void succeeded], [reversal.kind, reversal.status]
    assert Fake.row(@sale)[:voided]
    assert_includes audit_actions, 'pos_card_void'
    assert_match(/voided already/, assert_raises(Pos::Error) { reverse(1) }.message)
  end

  test 'a settled sale turns the void into a refund under its own reference' do
    Fake.settle!(@sale)
    reversal = reverse(1166)
    assert_equal %w[refund succeeded], [reversal.kind, reversal.status]
    assert_equal %w[failed succeeded], @checkout.pos_card_reversals.order(:id).pluck(:status)
    assert_equal({ kind: 'refund', total_cents: 1166 }, Fake.row(reversal.reference).slice(:kind, :total_cents))
    assert_not Fake.row(@sale)[:voided]
    assert_includes audit_actions, 'pos_card_refund'
  end

  test 'part refunds stop at the amount paid' do
    assert_equal %w[refund succeeded], reverse(500).then { |row| [row.kind, row.status] }
    assert_equal 500, @checkout.receipt[:card][:refunded_cents]
    assert_match(/between 0.01 and 6.66/, assert_raises(Pos::Error) { reverse(667) }.message)
    assert_equal 'succeeded', reverse(666).status
    assert_raises(Pos::Error) { reverse(1) }
  end

  test 'a reason is required, as for every other card reversal' do
    assert_match(/reason/, assert_raises(Pos::Error) { reverse(1166, reason: 'no') }.message)
    assert_empty @checkout.pos_card_reversals
  end

  test 'a lost refund answer stays unknown, blocks another, and is settled by a read-only recheck' do
    Fake.fail_next(:refund)
    assert_raises(Pos::Error) { reverse(500) }
    reversal = @checkout.pos_card_reversals.last
    assert_equal 'unknown', reversal.status
    assert_match(/still being checked/, assert_raises(Pos::Error) { reverse(500) }.message)
    assert_equal 'unknown', Pos::CardReversal.reconcile!(reversal).status, 'no record yet proves nothing'
    travel 11.minutes do
      assert_equal 'failed', Pos::CardReversal.reconcile!(reversal).status
    end
    assert_nil Fake.row(reversal.reference), 'the recheck never sends the refund again'
  end

  test 'a refund the provider did record is found by the recheck' do
    reversal = PosCardReversal.create!(pos_checkout: @checkout, pos_payment_attempt: @checkout.paid_attempt, kind: 'refund', amount_cents: 300,
      reference: 'RVfixture1', reason: 'Customer return', requested_by: @user, submitted_at: Time.current, status: 'unknown')
    Pos::DeviceReader.gateway(@setting).refund(reference: 'RVfixture1', original_reference: @sale, amount_cents: 300)
    assert_equal 'succeeded', Pos::CardReversal.reconcile!(reversal).status
  end

  test 'a lost void answer is settled from the sale record' do
    Fake.fail_next(:void)
    assert_raises(Pos::Error) { reverse(1166) }
    reversal = @checkout.pos_card_reversals.last
    assert_equal %w[void unknown], [reversal.kind, reversal.status]
    assert_equal 'unknown', Pos::CardReversal.reconcile!(reversal).status
    Pos::DeviceReader.gateway(@setting).void(reference: @sale, amount_cents: 1166)
    assert_equal 'succeeded', Pos::CardReversal.reconcile!(reversal).status
  end

  test 'an unpaid checkout cannot be reversed' do
    other = device_reader_checkout(display: PosDisplaySession.create!(user: @user, location: @location))
    assert_raises(Pos::Error) { Pos::CardReversal.call(checkout: other, amount_cents: 100, reason: 'Customer return', user: @user) }
  end
end
