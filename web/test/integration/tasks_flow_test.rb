# frozen_string_literal: true

require 'test_helper'

# Tasks tab: every task across projects, filterable by status, with transitions.
class TasksFlowTest < ActionDispatch::IntegrationTest
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

    @tenant = Tenant.create!(name: 'Test Co', subdomain: 'testco')
    @user = User.create!(email: 'tasks@example.com', password: 'password123', role: 'admin', tenant_id: @tenant.id)
    post login_path, params: { email: 'tasks@example.com', password: 'password123' }

    @project = Projects::Project.create!(name: 'Cleanup', tenant_id: @tenant.id)
    @task = Projects::Task.create!(project: @project, title: 'Fix duplicate SKUs', priority: 'high',
                                   tenant_id: @tenant.id)
  end

  def get_page(path, params: {})
    get(path, params: params.merge(shop: 'm11u0i-sb.myshopify.com', embedded: '1', host: 'test-host'))
  end

  test 'tasks index lists tasks across projects' do
    get_page projects_tasks_path
    assert_response :success
    assert_select 'h1', /Tasks/
    assert_select('p', /Fix duplicate SKUs/)
    assert_select('p', /Cleanup/)
  end

  test 'tasks index filters by status' do
    get_page projects_tasks_path, params: { status: 'done' }
    assert_response :success
    assert_select 'p', { text: /Fix duplicate SKUs/, count: 0 }
  end

  test 'task transition finishes a task' do
    get_page projects_tasks_path
    assert_select 'span', /todo/
    post transition_projects_task_path(@task, event: 'finish'),
         params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1' }
    assert_redirected_to @project
    assert @task.reload.done?
  end
end
