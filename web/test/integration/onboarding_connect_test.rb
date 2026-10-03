# frozen_string_literal: true

require 'test_helper'

class OnboardingConnectTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: 'Onboard Co', subdomain: 'onboardco')
    User.create!(email: 'ob@example.com', password: 'password123', role: 'admin',
      tenant_id: @tenant.id, name: 'OB')
    post login_path, params: { email: 'ob@example.com', password: 'password123' }
    Current.tenant = @tenant
  end

  teardown do
    Current.tenant = nil
    EnvStore::MANAGED_KEYS.each do |key|
      setting = Setting.find_by(key: key, tenant_id: @tenant.id)
      setting&.destroy
    end
  end

  test 'onboarding page shows inline credential form when unconfigured' do
    get onboarding_path
    assert_response :success
    assert_select 'form[action=?]', onboarding_connect_path
    assert_select 'input[name=shopify_client_id]'
    assert_select 'input[name=shopify_client_secret]'
    assert_select 'input[name=square_access_token]'
    assert_select 'button[type=submit]', /Connect and start first sync/
  end

  test 'saving only square keys keeps onboarding open with guidance' do
    assert_no_enqueued_jobs only: SyncJob do
      post onboarding_connect_path, params: { square_access_token: 'EAAA-test-token' }
    end
    assert_redirected_to onboarding_path
    follow_redirect!
    assert_match(/Add your Shopify client ID/, flash[:notice].to_s)
    assert_equal 'EAAA-test-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN', '')
  end

  test 'saving shopify keys configures, kicks off first sync, redirects to dashboard' do
    assert_enqueued_with(job: SyncJob, args: [{ tenant_id: @tenant.id, mode: 'manual', actor: 'ob@example.com' }]) do
      post onboarding_connect_path, params: {
        shopify_client_id: 'cid-123',
        shopify_client_secret: 'secret-456',
        square_access_token: 'EAAA-square'
      }
    end
    assert_redirected_to root_path
    assert_equal 'cid-123', EnvStore.fetch('SHOPIFY_CLIENT_ID', '')
    assert_equal 'secret-456', EnvStore.fetch('SHOPIFY_CLIENT_SECRET', '')
  end

  test 'blank fields are ignored so partial updates never wipe saved keys' do
    EnvStore.set('SHOPIFY_CLIENT_ID', 'existing-id')
    post onboarding_connect_path, params: { shopify_client_id: '', square_access_token: 'new-token' }
    assert_redirected_to onboarding_path
    assert_equal 'existing-id', EnvStore.fetch('SHOPIFY_CLIENT_ID', '')
  end

  test 'dashboard is reachable once configured' do
    EnvStore.set('SHOPIFY_CLIENT_ID', 'cid')
    EnvStore.set('SHOPIFY_CLIENT_SECRET', 'sec')
    get onboarding_path
    assert_redirected_to root_path
  end
end
