# frozen_string_literal: true

require 'test_helper'
require_relative 'walkthrough_helper'
require_relative '../support/self_service_billing_helper'

# End to end, through the real routes: a new business signs up by itself, accepts the terms, gets a
# trial, subscribes through Stripe Checkout, pays, misses a payment, recovers, cancels, lapses to
# read-only and subscribes again. Google and Stripe are doubled at the network edge: Google's
# verified identity is stubbed, and every Stripe API call is a WebMock stub of api.stripe.com with
# test-mode fixture ids, so the app's own Stripe client, signature check and webhook handler all run.
#
#   WALKTHROUGH_LOG=1 bin/rails test test/acceptance/self_service_signup_walkthrough_test.rb
class SelfServiceSignupWalkthroughTest < ActionDispatch::IntegrationTest
  include WalkthroughHelper
  include SelfServiceBillingHelper

  STRIPE = 'https://api.stripe.com/v1'

  setup do
    self_service_on!
    @requests = []
    stub_request(:get, "#{STRIPE}/account").to_return(json(id: 'acct_fixture'))
    stub_request(:get, "#{STRIPE}/prices/price_fixture_monthly").to_return(json(active: true, currency: 'usd', unit_amount: 49_900, product: 'prod_fixture', recurring: { interval: 'month', interval_count: 1 }))
    stub_request(:get, "#{STRIPE}/coupons/coupon_fixture").to_return(json(valid: true, percent_off: 50, duration: 'repeating', duration_in_months: 12))
  end

  def json(body)
    { status: 200, body: JSON.generate(body), headers: { 'Content-Type' => 'application/json' } }
  end

  def stripe_subscription_is(tenant, id, status, **options)
    stub_request(:get, "#{STRIPE}/subscriptions/#{id}").to_return(json(stripe_subscription(tenant, status: status, id: id, customer: 'cus_walk', **options)))
  end

  def stub_checkout(session_id)
    stub_request(:post, "#{STRIPE}/checkout/sessions").to_return do |request|
      @requests << URI.decode_www_form(request.body).to_h
      json(id: session_id, url: "https://checkout.stripe.com/c/pay/#{session_id}")
    end
  end

  def entitlement(tenant)
    WorkspaceEntitlement.for(tenant.reload).then { |e| "#{e.state}/#{e.access}" }
  end

  test 'a new business signs up, subscribes, pays, lapses and returns' do
    legacy = tenants(:default_tenant)

    # 1. Sign-up: the form, the terms, Google's verified identity.
    get start_path
    assert_response :success
    step 'sign-up form shows the terms box and the trial length'
    GoogleOauthService.stubs(:auth_url).returns('https://accounts.google.com/o/oauth2/auth')
    post start_path, params: { registration: { workspace_name: 'Juniper Books', requested_subdomain: 'juniper-books', accepted_terms: '1' } }
    assert_redirected_to 'https://accounts.google.com/o/oauth2/auth'
    GoogleOauthService.stubs(:exchange_code!).returns({ 'email' => 'owner@juniper-books.example', 'sub' => 'google-subject-juniper', 'email_verified' => true, 'name' => 'June Owner' })
    assert_difference ['Tenant.count', 'User.count', 'CustomerSubscription.count', 'WorkspaceDeployment.count'], 1 do
      get google_callback_path, params: { state: session[:oauth_state], code: 'google-code' }
    end
    assert_redirected_to workspace_path
    owner = User.find_by!(email: 'owner@juniper-books.example')
    tenant = owner.tenant
    row = CustomerSubscription.find_by!(tenant: tenant)
    assert_equal 'admin', owner.role
    refute tenant.billing_exempt
    assert_equal RupertBilling::TERMS_VERSION, row.signup_terms_version
    assert row.signup_terms_accepted_at
    assert_in_delta 14.days.from_now.to_f, row.trial_ends_at.to_f, 60
    assert_equal 'trialing/full', entitlement(tenant)
    step 'workspace, owner, terms record and 14-day trial created', entitlement(tenant)

    # 2. First-run checklist.
    get workspace_path
    assert_response :success
    assert_select '#setup-checklist li', 6
    assert_select '#setup-checklist li[data-step="1"][data-done="true"]'
    assert_select '#setup-checklist li[data-step="2"][data-done="true"]'
    assert_select '#setup-checklist li[data-step="4"][data-done="false"]', /Trial: full use until/
    step 'first-run checklist shows account and terms done, subscription to choose'

    # 3. Checkout: subscription mode, the configured price, the trial carried over.
    get billing_path
    assert_select '#subscription-state[data-state="trialing"][data-access="full"]'
    stub_checkout('cs_test_walk1')
    post billing_checkout_path, params: { plan: 'monthly', accepted: '1' }
    assert_redirected_to 'https://checkout.stripe.com/c/pay/cs_test_walk1'
    sent = @requests.last
    assert_equal 'subscription', sent['mode']
    assert_equal 'price_fixture_monthly', sent['line_items[0][price]']
    assert_equal tenant.id, sent['client_reference_id']
    assert_equal tenant.id, sent['subscription_data[metadata][rupert_tenant_id]']
    assert_equal row.reload.trial_ends_at.to_i.to_s, sent['subscription_data[trial_end]']
    assert_equal 'owner@juniper-books.example', sent['customer_email']
    assert_requested :post, "#{STRIPE}/checkout/sessions", headers: { 'Idempotency-Key' => "rupert-#{tenant.id}-#{row.checkout_token}", 'Stripe-Version' => '2025-06-30.basil' }
    step 'Checkout Session created in subscription mode with the configured price and trial end'

    # 4. Returning from Stripe proves nothing; only the signed webhook does.
    get billing_path, params: { checkout: 'returned' }
    assert_includes response.body, 'waiting for Stripe to confirm'
    assert_nil row.reload.stripe_subscription_id
    step 'browser return alone does not mark the workspace paid'

    stub_request(:get, "#{STRIPE}/checkout/sessions/cs_test_walk1").to_return(json(id: 'cs_test_walk1', client_reference_id: tenant.id, mode: 'subscription', status: 'complete', subscription: 'sub_walk1'))
    stripe_subscription_is(tenant, 'sub_walk1', 'trialing', period_end: row.trial_ends_at.to_i)
    completed = stripe_event('checkout.session.completed', { 'id' => 'cs_test_walk1', 'client_reference_id' => tenant.id })
    deliver_webhook(completed)
    assert_response :success
    assert_equal %w[sub_walk1 cus_walk trialing], row.reload.then { |r| [r.stripe_subscription_id, r.stripe_customer_id, r.status] }
    deliver_webhook(completed)
    assert_response :success
    assert_equal 2, BillingWebhookEvent.find_by!(stripe_event_id: completed['id']).deliveries
    step 'signed checkout.session.completed binds the subscription; its replay changes nothing', entitlement(tenant)

    # 5. The trial ends and the first invoice is paid: active.
    travel_to 15.days.from_now
    stripe_subscription_is(tenant, 'sub_walk1', 'active')
    deliver_webhook(stripe_event('invoice.paid', invoice_object('sub_walk1')))
    assert_response :success
    assert_equal 'active/full', entitlement(tenant)
    sign_in_owner(owner)
    get workspace_path
    assert_select '#setup-checklist li[data-step="4"][data-done="true"]', /Subscription active/
    get billing_path
    assert_select 'form[action=?]', billing_portal_path
    step 'first invoice paid: subscription active', entitlement(tenant)

    # 6. Customer Portal link for card updates and cancellation.
    stub_request(:post, "#{STRIPE}/billing_portal/sessions").to_return do |request|
      @requests << URI.decode_www_form(request.body).to_h
      json(url: 'https://billing.stripe.com/p/session/test_walk')
    end
    post billing_portal_path
    assert_redirected_to 'https://billing.stripe.com/p/session/test_walk'
    assert_equal({ 'customer' => 'cus_walk', 'configuration' => 'bpc_fixture', 'return_url' => 'https://billing.example.test/billing' }, @requests.last)
    step 'Customer Portal session opened for the workspace Stripe customer'

    # 7. A renewal fails: grace period, then read-only; then the card is fixed.
    travel_to 30.days.from_now
    stripe_subscription_is(tenant, 'sub_walk1', 'past_due')
    deliver_webhook(stripe_event('invoice.payment_failed', invoice_object('sub_walk1')))
    assert_equal 'past_due/full', entitlement(tenant)
    step 'renewal payment failed: full use during the grace period', entitlement(tenant)
    travel_to 8.days.from_now
    assert_equal 'past_due/read_only', entitlement(tenant)
    step 'grace period over: read-only', entitlement(tenant)
    stripe_subscription_is(tenant, 'sub_walk1', 'active')
    deliver_webhook(stripe_event('invoice.paid', invoice_object('sub_walk1')))
    assert_equal 'active/full', entitlement(tenant)
    step 'payment recovered: full use again', entitlement(tenant)

    # 8. The customer cancels in the portal; Stripe ends the subscription at period end.
    stripe_subscription_is(tenant, 'sub_walk1', 'active', cancel_at_period_end: true)
    deliver_webhook(stripe_event('customer.subscription.updated', { 'id' => 'sub_walk1' }))
    assert_equal 'active/full', entitlement(tenant)
    travel_to 25.days.from_now
    stripe_subscription_is(tenant, 'sub_walk1', 'canceled')
    deliver_webhook(stripe_event('customer.subscription.deleted', { 'id' => 'sub_walk1' }))
    assert_equal 'canceled/read_only', entitlement(tenant)
    assert_equal 'active', tenant.reload.status
    assert User.exists?(owner.id)
    step 'cancelled at period end: read-only, account and workspace kept', entitlement(tenant)

    # 9. The lapsed owner comes back and subscribes again with the same Stripe customer.
    sign_in_owner(owner)
    get billing_path
    assert_select '#subscription-state[data-state="canceled"][data-access="read_only"]'
    assert_select 'form[action=?]', billing_checkout_path
    stub_checkout('cs_test_walk2')
    post billing_checkout_path, params: { plan: 'monthly', accepted: '1' }
    assert_redirected_to 'https://checkout.stripe.com/c/pay/cs_test_walk2'
    assert_equal 'cus_walk', @requests.last['customer']
    refute @requests.last.key?('customer_email')
    refute @requests.last.key?('subscription_data[trial_end]'), 'a finished trial is not offered again'
    stub_request(:get, "#{STRIPE}/checkout/sessions/cs_test_walk2").to_return(json(id: 'cs_test_walk2', client_reference_id: tenant.id, mode: 'subscription', status: 'complete', subscription: 'sub_walk2'))
    stripe_subscription_is(tenant, 'sub_walk2', 'active')
    deliver_webhook(stripe_event('checkout.session.completed', { 'id' => 'cs_test_walk2', 'client_reference_id' => tenant.id }))
    assert_response :success
    assert_equal 'active/full', entitlement(tenant)
    # A late event for the ended subscription matches nothing and changes nothing.
    deliver_webhook(stripe_event('customer.subscription.deleted', { 'id' => 'sub_walk1' }))
    assert_response :success
    assert_equal %w[sub_walk2 active], row.reload.then { |r| [r.stripe_subscription_id, r.status] }
    step 'resubscribed with the same Stripe customer; late event for the old subscription ignored', entitlement(tenant)

    # 10. Throughout, the workspace that existed before was never touched.
    assert legacy.reload.billing_exempt
    assert_nil CustomerSubscription.find_by(tenant: legacy)
    assert_equal 'exempt/full', entitlement(legacy)
    step 'pre-existing workspace still exempt, with no subscription record'
  end

  private

  # Signs the owner in the way a returning Google user is: a session bound to the verified identity.
  def sign_in_owner(owner)
    GoogleOauthService.stubs(:exchange_code!).returns({ 'email' => owner.email, 'sub' => 'google-subject-juniper', 'email_verified' => true, 'name' => owner.name })
    get google_auth_path
    get google_callback_path, params: { state: session[:oauth_state], code: 'google-code' }
    assert_equal owner.id, session[:user_id]
  end
end
