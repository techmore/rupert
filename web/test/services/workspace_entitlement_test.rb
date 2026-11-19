# frozen_string_literal: true

require 'test_helper'
require_relative '../support/self_service_billing_helper'

class WorkspaceEntitlementTest < ActiveSupport::TestCase
  include SelfServiceBillingHelper

  test 'the switch is off unless set to an affirmative value' do
    self_service_off!
    refute SelfService.enabled?
    %w[0 false no off maybe].each do |value|
      ENV['RUPERT_SELF_SERVICE'] = value
      refute SelfService.enabled?, value
    end
    %w[1 true TRUE yes on].each do |value|
      ENV['RUPERT_SELF_SERVICE'] = value
      assert SelfService.enabled?, value
    end
  end

  test 'trial and grace lengths have defaults and ignore nonsense' do
    assert_equal 14, SelfService.trial_days
    assert_equal 7, SelfService.grace_days
    ENV.update('RUPERT_TRIAL_DAYS' => '30', 'RUPERT_BILLING_GRACE_DAYS' => '3')
    assert_equal [30, 3], [SelfService.trial_days, SelfService.grace_days]
    ENV.update('RUPERT_TRIAL_DAYS' => '-4', 'RUPERT_BILLING_GRACE_DAYS' => 'soon')
    assert_equal [14, 7], [SelfService.trial_days, SelfService.grace_days]
  end

  test 'checkout carries the rest of the trial, reuses the Stripe customer and adds Stripe Tax only when asked' do
    _tenant, _owner, row = billable_workspace(trial_ends_at: 10.days.from_now)
    fields = { 'customer_email' => 'owner@example.com' }
    RupertBilling.apply_self_service_checkout(fields, row)
    assert_equal({ 'customer_email' => 'owner@example.com', 'subscription_data[trial_end]' => row.trial_ends_at.to_i.to_s }, fields)

    row.update!(trial_ends_at: 1.day.from_now, stripe_customer_id: 'cus_returning')
    ENV['RUPERT_STRIPE_AUTOMATIC_TAX'] = '1'
    fields = { 'customer_email' => 'owner@example.com' }
    RupertBilling.apply_self_service_checkout(fields, row)
    assert_equal({ 'customer' => 'cus_returning', 'automatic_tax[enabled]' => 'true', 'customer_update[address]' => 'auto' }, fields,
      'a trial with under two days left is not sent: Stripe would refuse it')
  end

  test 'only an ended subscription is released for a new checkout' do
    _tenant, _owner, row = billable_workspace(status: 'active', stripe_subscription_id: 'sub_live', stripe_customer_id: 'cus_keep', checkout_token: 'tok', checkout_session_id: 'cs_done')
    RupertBilling.release_ended_subscription(row)
    assert_equal 'sub_live', row.reload.stripe_subscription_id
    row.update!(status: 'canceled', past_due_since: 1.day.ago)
    RupertBilling.release_ended_subscription(row)
    assert_equal [nil, nil, nil, nil, 'cus_keep'], row.reload.then { |r| [r.stripe_subscription_id, r.checkout_token, r.checkout_session_id, r.past_due_since, r.stripe_customer_id] }
  end

  test 'every workspace is exempt unless explicitly made billable' do
    assert tenants(:default_tenant).billing_exempt, 'the fixture stands for a workspace that existed before the migration'
    assert Tenant.create!(name: 'Made by an operator', subdomain: 'operator-made').billing_exempt
    entitlement = WorkspaceEntitlement.for(tenants(:default_tenant))
    assert_equal %w[exempt full], [entitlement.state, entitlement.access]
    assert WorkspaceEntitlement.for(nil).full?
  end

  test 'an exempt workspace stays full whatever its subscription record says' do
    tenant = tenants(:default_tenant)
    CustomerSubscription.create!(tenant: tenant, status: 'canceled', stripe_subscription_id: 'sub_old', trial_ends_at: 1.year.ago)
    assert WorkspaceEntitlement.for(tenant).exempt?
    assert WorkspaceEntitlement.for(tenant).full?
  end

  test 'a billable workspace is full in trial and read-only when the trial ends without a subscription' do
    tenant, _owner, row = billable_workspace
    entitlement = WorkspaceEntitlement.for(tenant)
    assert_equal %w[trialing full], [entitlement.state, entitlement.access]
    assert_in_delta row.trial_ends_at.to_f, entitlement.trial_ends_at.to_f, 1
    travel 15.days do
      entitlement = WorkspaceEntitlement.for(tenant)
      assert_equal %w[trial_expired read_only], [entitlement.state, entitlement.access]
    end
  end

  test 'a billable workspace without any record gets a trial counted from its creation' do
    tenant = Tenant.create!(name: 'No record', subdomain: 'no-record', billing_exempt: false)
    assert_equal 'trialing', WorkspaceEntitlement.for(tenant).state
    travel(15.days) { assert WorkspaceEntitlement.for(tenant).read_only? }
  end

  test 'active and Stripe-trialing subscriptions are full after the local trial has ended' do
    tenant, _owner, row = billable_workspace(trial_ends_at: 1.day.ago, status: 'active', stripe_subscription_id: 'sub_a')
    assert_equal %w[active full], WorkspaceEntitlement.for(tenant).then { |e| [e.state, e.access] }
    row.update!(status: 'trialing')
    assert_equal %w[trialing full], WorkspaceEntitlement.for(tenant).then { |e| [e.state, e.access] }
  end

  test 'a failed payment keeps full use for the grace period and then becomes read-only' do
    tenant, = billable_workspace(trial_ends_at: 1.month.ago, status: 'past_due', stripe_subscription_id: 'sub_p', past_due_since: Time.current)
    entitlement = WorkspaceEntitlement.for(tenant)
    assert_equal %w[past_due full], [entitlement.state, entitlement.access]
    assert_in_delta 7.days.from_now.to_f, entitlement.grace_ends_at.to_f, 2
    travel(6.days) { assert WorkspaceEntitlement.for(tenant).full? }
    travel(8.days) { assert_equal %w[past_due read_only], WorkspaceEntitlement.for(tenant).then { |e| [e.state, e.access] } }
  end

  test 'a cancelled subscription is read-only, and a complimentary plan overrides any lapse until its date' do
    tenant, _owner, row = billable_workspace(trial_ends_at: 1.month.ago, status: 'canceled', stripe_subscription_id: 'sub_c')
    assert_equal %w[canceled read_only], WorkspaceEntitlement.for(tenant).then { |e| [e.state, e.access] }
    row.update!(comp_until: 10.days.from_now)
    assert_equal %w[comped full], WorkspaceEntitlement.for(tenant).then { |e| [e.state, e.access] }
    travel(11.days) { assert WorkspaceEntitlement.for(tenant).read_only? }
  end

  test 'a malformed control-plane answer never locks an isolated workspace' do
    [nil, 'nope', {}, { 'state' => 'surprise', 'access' => 'none' }].each do |payload|
      assert WorkspaceEntitlement.from_control_plane(payload).full?, payload.inspect
    end
    lapsed = WorkspaceEntitlement.from_control_plane('state' => 'canceled', 'access' => 'read_only')
    assert_equal %w[canceled read_only], [lapsed.state, lapsed.access]
    round_trip = WorkspaceEntitlement.from_control_plane(WorkspaceEntitlement.new(state: 'past_due', access: 'full', grace_ends_at: Time.zone.parse('2027-01-02 03:04:05Z')).as_json)
    assert_equal Time.zone.parse('2027-01-02 03:04:05Z'), round_trip.grace_ends_at
  end

  test 'every state has a plain summary sentence' do
    WorkspaceEntitlement::STATES.each do |state|
      entitlement = WorkspaceEntitlement.new(state: state, access: 'full', trial_ends_at: 1.day.from_now, grace_ends_at: 1.day.from_now, comp_until: 1.day.from_now)
      assert_operator entitlement.summary.length, :>, 10
    end
  end
end
