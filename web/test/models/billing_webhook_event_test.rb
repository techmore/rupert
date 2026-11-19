# frozen_string_literal: true

require 'test_helper'

class BillingWebhookEventTest < ActiveSupport::TestCase
  test 'an event is applied once and a redelivery is only counted' do
    calls = 0
    event = { 'id' => 'evt_once', 'type' => 'invoice.paid', 'created' => 1_800_000_000 }
    assert_equal :processed, BillingWebhookEvent.process(event) { calls += 1 }
    assert_equal :duplicate, BillingWebhookEvent.process(event) { calls += 1 }
    assert_equal 1, calls
    row = BillingWebhookEvent.find_by!(stripe_event_id: 'evt_once')
    assert_equal ['invoice.paid', 2], [row.event_type, row.deliveries]
    assert row.processed_at
    assert_equal Time.zone.at(1_800_000_000), row.event_created_at
  end

  test 'a delivery that fails stays unprocessed so the retry applies it' do
    event = { 'id' => 'evt_retry', 'type' => 'customer.subscription.updated' }
    assert_raises(RupertBilling::Error) { BillingWebhookEvent.process(event) { raise RupertBilling::Error, 'not ready' } }
    assert_nil BillingWebhookEvent.find_by!(stripe_event_id: 'evt_retry').processed_at
    calls = 0
    assert_equal :processed, BillingWebhookEvent.process(event) { calls += 1 }
    assert_equal 1, calls
  end

  test 'an event without a Stripe event id is refused and stores nothing' do
    assert_no_difference 'BillingWebhookEvent.count' do
      [{}, { 'id' => '' }, { 'id' => 'sub_not_an_event' }, { 'id' => "evt_x\n" }].each do |event|
        assert_raises(RupertBilling::Error) { BillingWebhookEvent.process(event) { flunk 'must not run' } }
      end
    end
  end
end
