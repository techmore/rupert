# frozen_string_literal: true

# Shared setup for the self-service subscription tests. Everything is fictional and test-mode:
# the Stripe keys are fixture strings, and no test reaches Stripe (WebMock blocks the network;
# each test stubs the calls it expects).
module SelfServiceBillingHelper
  BILLING_ENV = {
    'RUPERT_BILLING_ENABLED' => 'true', 'CSP_STRIPE_SECRET_KEY' => 'sk_test_fixture', 'CSP_STRIPE_ACCOUNT_ID' => 'acct_fixture',
    'CSP_STRIPE_MONTHLY_PRICE_ID' => 'price_fixture_monthly', 'CSP_STRIPE_REFERRAL_COUPON_ID' => 'coupon_fixture',
    'CSP_STRIPE_WEBHOOK_SECRET' => 'whsec_fixture', 'CSP_STRIPE_PORTAL_CONFIGURATION_ID' => 'bpc_fixture',
    'RUPERT_PUBLIC_ORIGIN' => 'https://billing.example.test'
  }.freeze
  MANAGED_ENV = (BILLING_ENV.keys + %w[RUPERT_SELF_SERVICE RUPERT_TRIAL_DAYS RUPERT_BILLING_GRACE_DAYS RUPERT_STRIPE_AUTOMATIC_TAX]).freeze

  def self.included(base)
    base.setup { @self_service_saved_env = ENV.to_h.slice(*MANAGED_ENV) }
    base.teardown do
      MANAGED_ENV.each { |key| @self_service_saved_env.key?(key) ? ENV[key] = @self_service_saved_env[key] : ENV.delete(key) }
      Current.reset
    end
  end

  def self_service_on!(billing: true)
    ENV['RUPERT_SELF_SERVICE'] = '1'
    ENV.update(BILLING_ENV) if billing
  end

  def self_service_off!
    ENV.delete('RUPERT_SELF_SERVICE')
  end

  # A billable workspace with its owner, as self-service sign-up leaves it.
  def billable_workspace(name = 'Corner Bakery', trial_ends_at: 14.days.from_now, **subscription)
    tenant = Tenant.create!(name: name, subdomain: "#{name.parameterize}-#{SecureRandom.hex(3)}", billing_exempt: false)
    owner = User.create!(tenant: tenant, email: "owner-#{SecureRandom.hex(3)}@example.com", name: 'Owner', role: 'admin', password: 'password123')
    row = CustomerSubscription.create!(tenant: tenant, trial_ends_at: trial_ends_at, **subscription)
    [tenant, owner, row]
  end

  # What Stripe returns for a subscription (API 2025-06-30.basil: the period end is on the item).
  def stripe_subscription(tenant, status:, id: 'sub_fixture', customer: 'cus_fixture', period_end: 30.days.from_now.to_i, cancel_at_period_end: false)
    { 'id' => id, 'customer' => customer, 'status' => status, 'cancel_at_period_end' => cancel_at_period_end,
      'start_date' => Time.current.to_i, 'metadata' => { 'rupert_tenant_id' => tenant.id },
      'items' => { 'data' => [{ 'price' => { 'id' => 'price_fixture_monthly' }, 'quantity' => 1, 'current_period_end' => period_end }] } }
  end

  def stripe_event(type, object, id: "evt_#{SecureRandom.hex(8)}")
    { 'id' => id, 'type' => type, 'livemode' => false, 'created' => Time.current.to_i, 'data' => { 'object' => object } }
  end

  def invoice_object(subscription_id = 'sub_fixture')
    { 'id' => "in_#{SecureRandom.hex(4)}", 'parent' => { 'subscription_details' => { 'subscription' => subscription_id } } }
  end

  # Posts an event to the webhook endpoint with a valid Stripe signature for the fixture secret.
  def deliver_webhook(event, secret: 'whsec_fixture', at: Time.current.to_i)
    payload = JSON.generate(event)
    signature = OpenSSL::HMAC.hexdigest('SHA256', secret, "#{at}.#{payload}")
    post '/webhooks/stripe', params: payload, headers: { 'Content-Type' => 'application/json', 'Stripe-Signature' => "t=#{at},v1=#{signature}" }
  end
end
