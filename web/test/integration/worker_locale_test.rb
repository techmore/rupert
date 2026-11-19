# frozen_string_literal: true

require 'test_helper'

# A worker's language follows their staff record, never the request: Spanish staff pages render
# with lang="es" and Spanish dates; management pages and other people stay in English.
class WorkerLocaleTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @user = User.create!(tenant: @tenant, name: 'Lucía Ortiz', email: 'lucia@example.com', role: 'employee', password: 'password123')
    @worker = People::Employee.create!(user: @user, first_name: 'Lucía', last_name: 'Ortiz', employment_type: 'part_time', locale: 'es')
  end

  teardown { Current.reset }

  test 'the staff home renders in the worker language' do
    sign_in @user
    get employee_app_path
    assert_response :success
    assert_select 'html[lang=es]'
    get employee_app_path, headers: { 'Accept-Language' => 'fr' }
    assert_select 'html[lang=es]' # the request language never decides
  end

  test 'a worker without a language and a manager stay in English' do
    @worker.update!(locale: nil)
    sign_in @user
    get employee_app_path
    assert_select 'html[lang=en]'
    assert_equal :en, I18n.locale, 'the locale is restored after the request'
    sign_in users(:regular_user)
    get root_path
    assert_select 'html[lang=en]'
  end

  test 'an unknown language falls back to English' do
    @worker.update!(locale: 'xx')
    sign_in @user
    get employee_app_path
    assert_select 'html[lang=en]'
  end
end
