# frozen_string_literal: true

require 'test_helper'
require_relative '../support/self_service_billing_helper'

# The switch, the read-only gate, sign-up terms and the operator billing page.
class SelfServiceGateTest < ActionDispatch::IntegrationTest
  include SelfServiceBillingHelper

  setup do
    @legacy = tenants(:default_tenant)
    @legacy_admin = users(:regular_user)
    @operator = User.create!(tenant: Tenant.create!(name: 'Platform home', subdomain: 'platform-home-ss'), email: 'operator@example.org', password: 'password123', role: 'super_admin')
  end

  # --- switch off: nothing changes -------------------------------------------------------------

  test 'with the switch off the new routes do not exist' do
    self_service_off!
    sign_in @operator
    get '/platform/billing'
    assert_response :not_found
    patch "/platform/billing/#{@legacy.id}", params: { change: 'billable', confirm_subdomain: @legacy.subdomain }
    assert_response :not_found
    post "/internal/workspaces/#{SecureRandom.uuid}/entitlement"
    assert_response :not_found
    assert @legacy.reload.billing_exempt
    get platform_path
    assert_response :success
    refute_includes response.body, 'Workspace billing'
  end

  test 'with the switch off a lapsed billable workspace is not checked at all' do
    self_service_off!
    _tenant, owner, = billable_workspace(trial_ends_at: 1.year.ago, status: 'canceled', stripe_subscription_id: 'sub_gone')
    sign_in owner
    assert_difference 'Core::Customer.unscoped.count', 1 do
      post customers_path, params: { customer: { first_name: 'Still', last_name: 'Writable', email: 'still@example.com' } }
    end
    get billing_path
    assert_response :success
    assert_select '#subscription-state', false
    assert_includes response.body, 'Account access is free'
  end

  test 'with the switch off sign-up has no terms box and creates an exempt free workspace as before' do
    self_service_off!
    get start_path
    assert_response :success
    assert_select 'input[name=?]', 'registration[accepted_terms]', false
    user = VerifiedWorkspaceRegistration.call(info: { 'email' => 'free@example.com', 'sub' => 'free-subject', 'email_verified' => true },
      attributes: { 'workspace_name' => 'Free shop', 'requested_subdomain' => 'free-shop' })
    assert user.tenant.billing_exempt
    row = CustomerSubscription.find_by!(tenant: user.tenant)
    assert_equal 'free', row.status
    assert_nil row.trial_ends_at
    assert_nil row.signup_terms_accepted_at
  end

  # --- switch on: exempt workspaces untouched --------------------------------------------------

  test 'an exempt workspace reads and writes normally with the switch on, even with a dead subscription record' do
    self_service_on!
    CustomerSubscription.create!(tenant: @legacy, status: 'canceled', stripe_subscription_id: 'sub_legacy_dead', trial_ends_at: 2.years.ago)
    sign_in @legacy_admin
    get customers_path
    assert_response :success
    refute_includes response.body, 'read-only'
    assert_difference 'Core::Customer.unscoped.where(tenant_id: @legacy.id).count', 1 do
      post customers_path, params: { customer: { first_name: 'Exempt', last_name: 'Customer', email: 'exempt@example.com' } }
    end
  end

  # --- switch on: billable workspaces ----------------------------------------------------------

  test 'a workspace in trial has full use' do
    self_service_on!
    tenant, owner, = billable_workspace
    sign_in owner
    assert_difference 'Core::Customer.unscoped.where(tenant_id: tenant.id).count', 1 do
      post customers_path, params: { customer: { first_name: 'Trial', last_name: 'Customer', email: 'trial@example.com' } }
    end
  end

  test 'a lapsed workspace can read and export but not change anything, and nothing is deleted' do
    self_service_on!
    tenant, owner, = billable_workspace
    sign_in owner
    post customers_path, params: { customer: { first_name: 'Kept', last_name: 'Record', email: 'kept@example.com' } }
    assert_equal 1, Core::Customer.unscoped.where(tenant_id: tenant.id).count

    travel 15.days do
      sign_in owner
      get customers_path
      assert_response :success
      assert_includes response.body, 'read-only'
      assert_includes response.body, 'Kept'
      get export_customers_path
      assert_response :success
      assert_includes response.body, 'kept@example.com'

      assert_no_difference 'Core::Customer.unscoped.count' do
        post customers_path, params: { customer: { first_name: 'Not', last_name: 'Saved', email: 'no@example.com' } }
      end
      assert_response :see_other
      assert_includes flash[:alert], 'read-only'
      assert_no_difference 'Core::Customer.unscoped.count' do
        post customers_path, params: { customer: { first_name: 'Not', last_name: 'Saved' } }, as: :json
      end
      assert_response :payment_required
      assert_equal 'subscription_lapsed', response.parsed_body['error']

      # The owner can still reach Subscription, grant support access and sign out.
      get billing_path
      assert_response :success
      assert_select '#subscription-state[data-state=?][data-access=?]', 'trial_expired', 'read_only'
      assert_select 'form[action=?]', billing_checkout_path
      post support_access_path, params: { support_user_id: @operator.id, reason: 'Help me renew' }
      assert_redirected_to support_access_path
      delete logout_path
      assert_nil session[:user_id]
    end
    assert_equal 1, Core::Customer.unscoped.where(tenant_id: tenant.id).count
  end

  test 'a past-due workspace keeps writing during the grace period and is read-only after it' do
    self_service_on!
    tenant, owner, = billable_workspace(trial_ends_at: 1.month.ago, status: 'past_due', stripe_subscription_id: 'sub_late', past_due_since: Time.current)
    sign_in owner
    assert_difference 'Core::Customer.unscoped.where(tenant_id: tenant.id).count', 1 do
      post customers_path, params: { customer: { first_name: 'Grace', last_name: 'Period', email: 'grace@example.com' } }
    end
    travel 8.days do
      sign_in owner
      assert_no_difference 'Core::Customer.unscoped.count' do
        post customers_path, params: { customer: { first_name: 'Too', last_name: 'Late', email: 'late@example.com' } }
      end
      assert_response :see_other
    end
  end

  test 'the API answers reads for a lapsed workspace' do
    self_service_on!
    tenant, owner, = billable_workspace(trial_ends_at: 1.month.ago)
    Current.tenant = tenant
    _token, secret = ApiAccessToken.issue(attributes: { name: 'Reader', scopes: ['inventory:read'] }, user: owner, tenant: tenant)
    Current.reset
    get '/api/v1/inventory', headers: { 'Authorization' => "Bearer #{secret}" }
    assert_response :success
  end

  # --- sign-up --------------------------------------------------------------------------------

  test 'with the switch on sign-up requires the terms and starts a billable trial' do
    self_service_on!
    ENV['RUPERT_TRIAL_DAYS'] = '21'
    get start_path
    assert_select 'input[type=checkbox][name=?][required]', 'registration[accepted_terms]'
    assert_select "a[href='#{terms_of_service_path}']", minimum: 1
    assert_select "a[href='#{privacy_policy_path}']", minimum: 1
    assert_includes response.body, '21 days'

    GoogleOauthService.expects(:auth_url).never
    post start_path, params: { registration: { workspace_name: 'Corner Bakery', requested_subdomain: 'corner-bakery' } }
    assert_response :unprocessable_entity
    assert_includes response.body, 'Accept the terms'
    assert_select 'input[name=?][value=?]', 'registration[workspace_name]', 'Corner Bakery'
  end

  test 'a registration without recorded terms is refused when the switch is on' do
    self_service_on!
    assert_no_difference ['Tenant.count', 'User.count'] do
      assert_raises(GoogleOauthService::ExchangeError) do
        VerifiedWorkspaceRegistration.call(info: { 'email' => 'skip@example.com', 'sub' => 'skip', 'email_verified' => true },
          attributes: { 'workspace_name' => 'Skipped terms', 'requested_subdomain' => 'skipped-terms' })
      end
    end
  end

  # --- operator billing page ------------------------------------------------------------------

  test 'only a platform administrator can open the operator billing page' do
    self_service_on!
    get platform_billing_path
    assert_redirected_to login_path
    sign_in @legacy_admin
    get platform_billing_path
    assert_response :forbidden
    patch platform_billing_workspace_path(@legacy.id), params: { change: 'billable', confirm_subdomain: @legacy.subdomain }
    assert_response :forbidden
    assert @legacy.reload.billing_exempt
  end

  test 'the operator sees every workspace with its state' do
    self_service_on!
    billable_workspace('Lapsed Shop', trial_ends_at: 1.month.ago, status: 'canceled', stripe_subscription_id: 'sub_x')
    billable_workspace('Paying Shop', trial_ends_at: 1.month.ago, status: 'active', stripe_subscription_id: 'sub_y')
    sign_in @operator
    get platform_billing_path
    assert_response :success
    assert_select "tr[data-workspace='#{@legacy.subdomain}']", /Exempt/
    assert_select 'tr', /Lapsed Shop.*Canceled.*Read-only/m
    assert_select 'tr', /Paying Shop.*Active.*Full/m
    get platform_path
    assert_select 'a[href=?]', platform_billing_path
  end

  test 'the operator can exempt a billable workspace, which restores full use at once' do
    self_service_on!
    tenant, owner, = billable_workspace('Friend Shop', trial_ends_at: 1.month.ago)
    assert WorkspaceEntitlement.for(tenant).read_only?
    sign_in @operator
    patch platform_billing_workspace_path(tenant.id), params: { change: 'exempt' }
    assert_redirected_to platform_billing_path
    assert tenant.reload.billing_exempt
    delete logout_path
    sign_in owner
    assert_difference 'Core::Customer.unscoped.where(tenant_id: tenant.id).count', 1 do
      post customers_path, params: { customer: { first_name: 'Back', last_name: 'Again', email: 'back@example.com' } }
    end
  end

  test 'making a workspace billable needs its address typed, starts a full trial and never applies to the operator home' do
    self_service_on!
    sign_in @operator
    patch platform_billing_workspace_path(@legacy.id), params: { change: 'billable', confirm_subdomain: 'wrong' }
    assert_redirected_to platform_billing_path
    assert @legacy.reload.billing_exempt, 'a mistyped confirmation changes nothing'
    patch platform_billing_workspace_path(@operator.tenant_id), params: { change: 'billable', confirm_subdomain: @operator.tenant.subdomain }
    assert @operator.tenant.reload.billing_exempt

    other = Tenant.create!(name: 'Opted in', subdomain: 'opted-in', created_at: 2.years.ago)
    patch platform_billing_workspace_path(other.id), params: { change: 'billable', confirm_subdomain: 'opted-in' }
    refute other.reload.billing_exempt
    entitlement = WorkspaceEntitlement.for(other)
    assert_equal %w[trialing full], [entitlement.state, entitlement.access], 'an old workspace still gets a whole trial, never an instant lock'
    assert_in_delta 14.days.from_now.to_f, entitlement.trial_ends_at.to_f, 5
  end

  test 'the operator can comp a plan until a date and end it, without touching Stripe' do
    self_service_on!
    tenant, = billable_workspace('Comped Shop', trial_ends_at: 1.month.ago)
    sign_in @operator
    RupertBilling.expects(:api).never
    patch platform_billing_workspace_path(tenant.id), params: { change: 'comp', comp_until: 30.days.from_now.to_date.iso8601, comp_note: 'Launch partner' }
    assert_redirected_to platform_billing_path
    assert_equal %w[comped full], WorkspaceEntitlement.for(tenant).then { |e| [e.state, e.access] }
    assert_equal 'Launch partner', CustomerSubscription.find_by!(tenant: tenant).comp_note
    patch platform_billing_workspace_path(tenant.id), params: { change: 'comp', comp_until: 'yesterday' }
    assert_includes flash[:alert], 'calendar date'
    patch platform_billing_workspace_path(tenant.id), params: { change: 'comp', comp_until: 1.day.ago.to_date.iso8601 }
    assert_includes flash[:alert], 'future'
    patch platform_billing_workspace_path(tenant.id), params: { change: 'end_comp' }
    assert WorkspaceEntitlement.for(tenant).read_only?
    patch platform_billing_workspace_path(tenant.id), params: { change: 'something-else' }
    assert_includes flash[:alert], 'Choose a change'
  end

  # --- isolated workspace nodes ---------------------------------------------------------------

  test 'the control plane tells an isolated node its entitlement only with that instance secret' do
    self_service_on!
    tenant, owner, = billable_workspace('Isolated Shop', trial_ends_at: 1.month.ago, status: 'canceled', stripe_subscription_id: 'sub_iso')
    deployment = WorkspaceDeployment.request!(tenant: tenant, owner: owner)
    post "/internal/workspaces/#{deployment.instance_id}/entitlement", headers: { 'Authorization' => "Bearer #{deployment.instance_secret}" }
    assert_response :not_found, 'an instance that is not ready has no entitlement endpoint'
    deployment.update!(status: 'ready')
    post "/internal/workspaces/#{deployment.instance_id}/entitlement", headers: { 'Authorization' => 'Bearer wrong' }
    assert_response :unauthorized
    post "/internal/workspaces/#{deployment.instance_id}/entitlement", headers: { 'Authorization' => "Bearer #{deployment.instance_secret}" }
    assert_response :success
    assert_equal({ 'state' => 'canceled', 'access' => 'read_only' }, response.parsed_body.slice('state', 'access'))
    assert_equal 'no-store', response.headers['Cache-Control']
  end

  test 'a provisioning job tells the new instance about the switch only while it is on' do
    saved = ENV.to_h.slice('RUPERT_PROVISION_WORKSPACES')
    ENV['RUPERT_PROVISION_WORKSPACES'] = 'true'
    2.times do |index|
      tenant, owner, = billable_workspace("Queued Shop #{index}")
      owner.google_login_identities.create!(email: owner.email, google_subject: "queued-subject-#{index}")
      WorkspaceDeployment.request!(tenant: tenant, owner: owner)
    end
    self_service_off!
    refute WorkspaceProvisioning.claim.key?('self_service')
    self_service_on!
    assert_equal true, WorkspaceProvisioning.claim['self_service']
  ensure
    saved.key?('RUPERT_PROVISION_WORKSPACES') ? ENV['RUPERT_PROVISION_WORKSPACES'] = saved['RUPERT_PROVISION_WORKSPACES'] : ENV.delete('RUPERT_PROVISION_WORKSPACES')
  end

  test 'a lapsed isolated workspace is read-only on its own node, and its owner is sent nowhere surprising' do
    self_service_on!(billing: false)
    tenant, owner, = billable_workspace('Node Shop')
    owner.google_login_identities.create!(email: owner.email, google_subject: 'node-subject')
    saved = ENV.to_h.slice('RUPERT_NODE_MODE', 'RUPERT_TENANT_ID', 'RUPERT_INSTANCE_HOSTNAME', 'RUPERT_CONTROL_PLANE_ORIGIN')
    ENV.update('RUPERT_NODE_MODE' => 'workspace', 'RUPERT_TENANT_ID' => tenant.id, 'RUPERT_INSTANCE_HOSTNAME' => 'node.example.org', 'RUPERT_CONTROL_PLANE_ORIGIN' => 'https://control.example.org')
    host! 'node.example.org'
    WorkspaceNode.stubs(:entitlement).returns({ 'state' => 'active', 'access' => 'full' })
    sign_in owner
    assert_equal owner.id, session[:user_id]
    assert_difference 'Core::Customer.unscoped.where(tenant_id: tenant.id).count', 1 do
      post customers_path, params: { customer: { first_name: 'Node', last_name: 'Paid', email: 'node@example.com' } }
    end
    WorkspaceNode.stubs(:entitlement).returns({ 'state' => 'canceled', 'access' => 'read_only' })
    get customers_path
    assert_response :success
    assert_no_difference 'Core::Customer.unscoped.count' do
      post customers_path, params: { customer: { first_name: 'Node', last_name: 'Lapsed', email: 'lapsed@example.com' } }
    end
    assert_response :see_other
    assert_includes flash[:alert], 'read-only'
  ensure
    saved.each { |key, value| ENV[key] = value }
    (%w[RUPERT_NODE_MODE RUPERT_TENANT_ID RUPERT_INSTANCE_HOSTNAME RUPERT_CONTROL_PLANE_ORIGIN] - saved.keys).each { |key| ENV.delete(key) }
  end

  test 'an isolated node fails open when the control plane cannot answer and uses its last answer otherwise' do
    saved = ENV.to_h.slice('RUPERT_NODE_MODE')
    ENV['RUPERT_NODE_MODE'] = 'workspace'
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(store)
    WorkspaceNode.stubs(:control_request).raises(RupertBilling::Error, 'down')
    assert SelfService.entitlement_for(@legacy).full?, 'no answer ever: full access'

    store.clear
    WorkspaceNode.stubs(:control_request).returns({ 'state' => 'canceled', 'access' => 'read_only' })
    assert SelfService.entitlement_for(@legacy).read_only?
    WorkspaceNode.stubs(:control_request).raises(RupertBilling::Error, 'down')
    assert SelfService.entitlement_for(@legacy).read_only?, 'inside five minutes the answer is reused without a call'
    store.delete("#{WorkspaceNode::ENTITLEMENT_CACHE_KEY}:fresh")
    assert SelfService.entitlement_for(@legacy).read_only?, 'during an outage the last answer stands'
    store.clear
    WorkspaceNode.stubs(:control_request).returns({ 'state' => 'active', 'access' => 'full' })
    assert_equal 'active', SelfService.entitlement_for(@legacy).state
  ensure
    saved.key?('RUPERT_NODE_MODE') ? ENV['RUPERT_NODE_MODE'] = saved['RUPERT_NODE_MODE'] : ENV.delete('RUPERT_NODE_MODE')
  end
end
