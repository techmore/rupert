# frozen_string_literal: true

require 'test_helper'

class EnvPreviewTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: 'Preview Co', subdomain: 'previewco')
    User.create!(email: 'prev@example.com', password: 'password123', role: 'admin',
      tenant_id: @tenant.id, name: 'Prev')
    post login_path, params: { email: 'prev@example.com', password: 'password123' }
    Current.tenant = @tenant
  end

  teardown do
    Current.tenant = nil
    Setting.where(tenant_id: @tenant.id).delete_all
  end

  test 'preview reports new and updated keys without writing anything' do
    EnvStore.set('SQUARE_ACCESS_TOKEN', 'existing-token')

    post env_preview_settings_path,
      params: { text: "SQUARE_ACCESS_TOKEN=new-token\nBRAND_NEW_KEY=value\nNOT_A_MANAGED_KEY=x" },
      headers: { 'X-Requested-With' => 'XMLHttpRequest' }
    assert_response :success
    body = JSON.parse(response.body)

    assert_equal 0, body['added']
    assert_equal 1, body['updated']
    assert_includes body['unknown'], 'NOT_A_MANAGED_KEY'
    assert_includes body['unknown'], 'BRAND_NEW_KEY'

    # Preview must not write.
    assert_equal 'existing-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN', '')
    assert_nil Setting.find_by(key: 'BRAND_NEW_KEY', tenant_id: @tenant.id)
  end

  test 'preview rejects blank input' do
    post env_preview_settings_path, params: { text: '' }, headers: { 'X-Requested-With' => 'XMLHttpRequest' }
    assert_response :unprocessable_entity
  end
end
