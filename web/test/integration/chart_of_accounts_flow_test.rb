# frozen_string_literal: true

require 'test_helper'

class ChartOfAccountsFlowTest < ActionDispatch::IntegrationTest
  module TestShopifySession
    def current_shopify_session
      @test_session ||= ShopifyAPI::Auth::Session.new(
        shop: 'm11u0i-sb.myshopify.com',
        access_token: 'test-token',
        is_online: false,
        expires: Time.now + 3600
      )
    end
  end

  ShopifyApp::TokenExchange.prepend(TestShopifySession)

  setup do
    ShopifyAPI::Context.setup(
      api_key: 'test-key',
      api_secret_key: 'test-secret',
      api_version: ShopifyAPI::AdminVersions::SUPPORTED_ADMIN_VERSIONS.first,
      host_name: 'localhost',
      scope: 'read_products',
      is_private: false,
      is_embedded: false
    )
    Shop.create!(shopify_domain: 'm11u0i-sb.myshopify.com', shopify_token: 'test-token')

    @tenant = Tenant.create!(name: 'Ledger Co', subdomain: 'ledgerco')
    @user = User.create!(email: 'coa@example.com', password: 'password123', role: 'admin', tenant_id: @tenant.id)
    post login_path, params: { email: 'coa@example.com', password: 'password123' }
    Current.tenant = @tenant
  end

  teardown do
    Current.tenant = nil
  end

  def get_page(path)
    get(path, params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1', host: 'test-host' })
  end

  test 'chart seeds the standard accounts on first visit' do
    assert_equal 0, Finance::Account.count
    get_page finance_chart_of_accounts_path
    assert_response :success
    assert_select 'h1', /Chart of accounts/
    assert_select 'td', /1000/
    assert_select 'td', /Cash/
    assert Finance::Account.count >= 20
  end

  test 'adding and editing an account' do
    Finance::ChartOfAccounts.seed!
    get_page finance_chart_of_accounts_path
    assert_response :success

    post finance_chart_of_accounts_path, params: {
      account: { code: '7000', name: 'Gift card income', account_type: 'revenue' },
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success
    account = Finance::Account.find_by!(code: '7000')
    assert_equal 'revenue', account.account_type
    assert_equal 'credit', account.normal_balance
    assert_select 'td', /Gift card income/

    patch finance_chart_of_account_path(account), params: {
      account: { code: '7000', name: 'Gift cards', account_type: 'revenue', active: '1' },
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success
    assert_equal 'Gift cards', account.reload.name
  end

  test 'archiving hides the account from active count but keeps it in the chart' do
    Finance::ChartOfAccounts.seed!
    account = Finance::Account.find_by!(code: '6100')

    post archive_finance_chart_of_account_path(account), params: {
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success
    assert_not account.reload.active

    post restore_finance_chart_of_account_path(account), params: {
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success
    assert account.reload.active
  end

  test 'reader cannot add accounts' do
    User.create!(email: 'coa-reader@example.com', password: 'password123', role: 'reader',
                 tenant_id: @tenant.id)
    post login_path, params: { email: 'coa-reader@example.com', password: 'password123' }
    post finance_chart_of_accounts_path, params: {
      account: { code: '9000', name: 'Nope', account_type: 'expense' },
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    assert_redirected_to root_path
  end
end
