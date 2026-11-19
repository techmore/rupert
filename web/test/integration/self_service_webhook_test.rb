# frozen_string_literal: true

require 'test_helper'
require_relative '../support/self_service_billing_helper'

# The Stripe webhook endpoint with self-service on: signatures, redelivery, event order,
# payment failure and recovery, cancellation, and exempt workspaces. Stripe is doubled:
# RupertBilling.api is stubbed with what Stripe would return, and nothing leaves the process.
class SelfServiceWebhookTest < ActionDispatch::IntegrationTest
  include SelfServiceBillingHelper

  setup do
    self_service_on!
    @tenant, @owner, @row = billable_workspace(trial_ends_at: 1.day.ago, status: 'active', stripe_subscription_id: 'sub_fixture', stripe_customer_id: 'cus_fixture', plan: 'monthly')
  end

  def stripe_says(status, **options)
    RupertBilling.stubs(:api).with(:get, 'subscriptions/sub_fixture').returns(stripe_subscription(@tenant, status: status, **options))
  end

  def state
    WorkspaceEntitlement.for(@tenant.reload).then { |e| [e.state, e.access] }
  end

  test 'a forged, stale or unsigned delivery is refused and records nothing' do
    RupertBilling.expects(:api).never
    event = stripe_event('customer.subscription.deleted', { 'id' => 'sub_fixture' })
    assert_no_difference 'BillingWebhookEvent.count' do
      deliver_webhook(event, secret: 'whsec_attacker')
      assert_response :bad_request
      deliver_webhook(event, at: 10.minutes.ago.to_i)
      assert_response :bad_request
      post '/webhooks/stripe', params: JSON.generate(event), headers: { 'Content-Type' => 'application/json' }
      assert_response :bad_request
      post '/webhooks/stripe', params: JSON.generate(event), headers: { 'Content-Type' => 'application/json', 'Stripe-Signature' => 't=abc,v1=' }
      assert_response :bad_request
    end
    assert_equal 'active', @row.reload.status
  end

  test 'a signed payload that is not an event is refused' do
    deliver_webhook([1, 2, 3])
    assert_response :bad_request
    deliver_webhook({ 'type' => 'invoice.paid', 'livemode' => false })
    assert_response :bad_request
    assert_equal 0, BillingWebhookEvent.count
  end

  test 'a live-mode event is refused while test keys are configured' do
    event = stripe_event('customer.subscription.updated', { 'id' => 'sub_fixture' }).merge('livemode' => true)
    RupertBilling.expects(:api).never
    deliver_webhook(event)
    assert_response :bad_request
    assert_nil BillingWebhookEvent.find_by!(stripe_event_id: event['id']).processed_at
  end

  test 'a replayed event is acknowledged without being applied again' do
    event = stripe_event('customer.subscription.updated', { 'id' => 'sub_fixture' })
    RupertBilling.expects(:api).with(:get, 'subscriptions/sub_fixture').once.returns(stripe_subscription(@tenant, status: 'past_due'))
    3.times do
      deliver_webhook(event)
      assert_response :success
    end
    assert_equal 'past_due', @row.reload.status
    assert_equal 3, BillingWebhookEvent.find_by!(stripe_event_id: event['id']).deliveries
    assert_equal 1, BillingWebhookEvent.count
  end

  test 'a delivery that cannot be applied is retried, then applied once' do
    event = stripe_event('customer.subscription.updated', { 'id' => 'sub_fixture' })
    RupertBilling.stubs(:api).with(:get, 'subscriptions/sub_fixture').raises(RupertBilling::Error, 'Stripe could not complete this request.')
    deliver_webhook(event)
    assert_response :bad_request
    assert_nil BillingWebhookEvent.find_by!(stripe_event_id: event['id']).processed_at
    stripe_says('past_due')
    deliver_webhook(event)
    assert_response :success
    assert_equal 'past_due', @row.reload.status
    assert BillingWebhookEvent.find_by!(stripe_event_id: event['id']).processed_at
  end

  test 'events out of order never restore an older state' do
    # Stripe now says canceled. An older "updated: active" event arrives afterwards: its own
    # status field is ignored, the current Stripe state is read instead.
    stripe_says('canceled')
    deliver_webhook(stripe_event('customer.subscription.deleted', { 'id' => 'sub_fixture', 'status' => 'canceled' }))
    assert_response :success
    deliver_webhook(stripe_event('customer.subscription.updated', { 'id' => 'sub_fixture', 'status' => 'active' }))
    assert_response :success
    deliver_webhook(stripe_event('invoice.paid', invoice_object))
    assert_response :success
    assert_equal 'canceled', @row.reload.status
    assert_equal %w[canceled read_only], state
  end

  test 'a payment failure starts the grace period and a recovered payment clears it' do
    stripe_says('past_due')
    deliver_webhook(stripe_event('invoice.payment_failed', invoice_object))
    assert_response :success
    started = @row.reload.past_due_since
    assert started
    assert_equal %w[past_due full], state

    travel 3.days do
      # A second failed retry must not restart the grace period.
      deliver_webhook(stripe_event('invoice.payment_failed', invoice_object))
      assert_equal started, @row.reload.past_due_since
    end
    travel(8.days) { assert_equal %w[past_due read_only], state }

    travel 9.days do
      period_end = 30.days.from_now.to_i
      stripe_says('active', period_end: period_end)
      deliver_webhook(stripe_event('invoice.paid', invoice_object))
      assert_response :success
      assert_nil @row.reload.past_due_since
      assert_equal period_end, @row.current_period_end.to_i
      assert_equal %w[active full], state
    end
  end

  test 'cancelling at period end stays active until Stripe ends the subscription, then is read-only with data intact' do
    Current.tenant = @tenant
    Core::Customer.create!(first_name: 'Kept', last_name: 'Forever', source: 'manual', external_id: 'manual:kept')
    Current.reset

    stripe_says('active', cancel_at_period_end: true)
    deliver_webhook(stripe_event('customer.subscription.updated', { 'id' => 'sub_fixture' }))
    assert @row.reload.cancel_at_period_end
    assert_equal %w[active full], state

    stripe_says('canceled')
    deliver_webhook(stripe_event('customer.subscription.deleted', { 'id' => 'sub_fixture' }))
    assert_response :success
    assert_equal %w[canceled read_only], state
    assert_equal 1, Core::Customer.unscoped.where(tenant_id: @tenant.id).count, 'cancellation deletes nothing'
    assert_equal 'active', @tenant.reload.status, 'the workspace itself stays open for reading'
  end

  test 'a subscription event that arrives before checkout completes binds to the open checkout' do
    tenant, _owner, row = billable_workspace('Early Event Shop', checkout_token: 'tok', checkout_session_id: 'cs_open', checkout_expires_at: 1.hour.from_now, plan: 'monthly')
    fresh = stripe_subscription(tenant, status: 'trialing', id: 'sub_early', customer: 'cus_early')
    RupertBilling.stubs(:api).with(:get, 'subscriptions/sub_early').returns(fresh)
    deliver_webhook(stripe_event('customer.subscription.created', { 'id' => 'sub_early', 'metadata' => { 'rupert_tenant_id' => tenant.id } }))
    assert_response :success
    assert_equal %w[sub_early cus_early trialing], row.reload.then { |r| [r.stripe_subscription_id, r.stripe_customer_id, r.status] }

    # checkout.session.completed then arrives late and agrees.
    RupertBilling.stubs(:api).with(:get, 'checkout/sessions/cs_open').returns({ 'client_reference_id' => tenant.id, 'mode' => 'subscription', 'status' => 'complete', 'subscription' => 'sub_early' })
    deliver_webhook(stripe_event('checkout.session.completed', { 'id' => 'cs_open', 'client_reference_id' => tenant.id }))
    assert_response :success
    assert_equal 'sub_early', row.reload.stripe_subscription_id
  end

  test 'a subscription event cannot attach to a workspace that has no open checkout' do
    tenant, _owner, row = billable_workspace('No Checkout Shop')
    RupertBilling.expects(:api).never
    deliver_webhook(stripe_event('customer.subscription.created', { 'id' => 'sub_stranger', 'metadata' => { 'rupert_tenant_id' => tenant.id } }))
    assert_response :success
    assert_nil row.reload.stripe_subscription_id
  end

  test 'a subscription whose Stripe metadata names another workspace is refused' do
    other = Tenant.create!(name: 'Other', subdomain: 'other-webhook-shop', billing_exempt: false)
    RupertBilling.stubs(:api).with(:get, 'subscriptions/sub_fixture').returns(stripe_subscription(other, status: 'canceled'))
    deliver_webhook(stripe_event('customer.subscription.deleted', { 'id' => 'sub_fixture' }))
    assert_response :bad_request
    assert_equal 'active', @row.reload.status
  end

  test 'an exempt workspace is untouched by any subscription event' do
    legacy = tenants(:default_tenant)
    RupertBilling.expects(:api).never
    %w[customer.subscription.created customer.subscription.updated customer.subscription.deleted].each do |type|
      deliver_webhook(stripe_event(type, { 'id' => 'sub_unknown', 'metadata' => { 'rupert_tenant_id' => legacy.id } }))
      assert_response :success
    end
    %w[invoice.paid invoice.payment_failed].each do |type|
      deliver_webhook(stripe_event(type, invoice_object('sub_unknown')))
      assert_response :success
    end
    assert legacy.reload.billing_exempt
    assert_nil CustomerSubscription.find_by(tenant: legacy)
    assert WorkspaceEntitlement.for(legacy).exempt?
  end

  test 'an exempt workspace that does hold a subscription record keeps full use when it is cancelled' do
    legacy = tenants(:default_tenant)
    CustomerSubscription.create!(tenant: legacy, status: 'active', stripe_subscription_id: 'sub_legacy', stripe_customer_id: 'cus_legacy', plan: 'monthly')
    RupertBilling.stubs(:api).with(:get, 'subscriptions/sub_legacy').returns(stripe_subscription(legacy, status: 'canceled', id: 'sub_legacy', customer: 'cus_legacy'))
    deliver_webhook(stripe_event('customer.subscription.deleted', { 'id' => 'sub_legacy' }))
    assert_response :success
    assert legacy.reload.billing_exempt
    assert_equal %w[exempt full], WorkspaceEntitlement.for(legacy).then { |e| [e.state, e.access] }
  end

  test 'with the switch off the endpoint behaves as before: no ledger, created events ignored' do
    self_service_off!
    ENV.update(BILLING_ENV)
    event = stripe_event('customer.subscription.updated', { 'id' => 'sub_fixture' })
    RupertBilling.expects(:api).with(:get, 'subscriptions/sub_fixture').twice.returns(stripe_subscription(@tenant, status: 'past_due'))
    2.times do
      deliver_webhook(event)
      assert_response :success
    end
    deliver_webhook(stripe_event('customer.subscription.created', { 'id' => 'sub_fixture' }))
    assert_response :success
    assert_equal 0, BillingWebhookEvent.count
    assert_equal 'past_due', @row.reload.status
    assert_nil @row.past_due_since, 'the grace clock is only kept with the switch on'
  end

  test 'with billing not configured the endpoint refuses everything' do
    ENV.delete('CSP_STRIPE_WEBHOOK_SECRET')
    deliver_webhook(stripe_event('invoice.paid', invoice_object))
    assert_response :bad_request
  end
end
