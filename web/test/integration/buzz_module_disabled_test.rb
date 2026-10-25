# frozen_string_literal: true

require 'test_helper'

# The optional Buzz module (web/engines/buzz) is off unless RUPERT_BUZZ_ENABLED=1,
# and this suite runs with it off. Off must be exactly the Rupert without it: the
# old addresses still lead to team chat, and there is no Buzz page, navigation,
# permission, scheduled job, browser code or relay client. Its enabled-state tests
# live in engines/buzz/test and run in their own process.
class BuzzModuleDisabledTest < ActionDispatch::IntegrationTest
  setup do
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
    @admin = users(:regular_user)
    @admin.update!(role: 'super_admin')
  end

  test 'the module is off and none of its code is loaded' do
    assert_equal false, Rails.application.config.x.buzz_enabled
    refute defined?(Buzz::Engine)
    refute defined?(Buzz::Chat)
    refute defined?(Buzz::Socket)
    refute(Rails.application.railties.any? { |railtie| railtie.class.name.to_s.start_with?('Buzz') })
  end

  test 'old Buzz addresses still lead to team chat and no Buzz page exists' do
    %w[/admin/buzz /buzz /buzz/chat].each do |path|
      get path
      assert_redirected_to '/chat', path
    end
    buzz_routes = Rails.application.routes.routes.select { |route| route.path.spec.to_s.start_with?('/buzz', '/admin/buzz') }
    assert_equal ['/admin/buzz(.:format)', '/buzz(.:format)', '/buzz/chat(.:format)'], buzz_routes.map { |route| route.path.spec.to_s }.sort
    assert(Rails.application.routes.routes.none? { |route| route.defaults[:controller].to_s.start_with?('buzz') })
    refute Rails.application.routes.url_helpers.respond_to?(:buzz_setup_path)
  end

  test 'no navigation entry, for anyone' do
    assert_empty ModuleRegistry.instance_variable_get(:@extensions)
    assert_nil ModuleRegistry.find('buzz')
    assert_same ModuleRegistry.singleton_class::AREAS, ModuleRegistry.areas, "areas are the built-in ones, untouched"
    refute_includes ModuleRegistry.nav_for(@admin).map(&:key), 'buzz'
    post login_path, params: { email: @admin.email, password: 'password' }
    get people_employees_path
    assert_response :success
    assert_select "a[href^='/buzz']", 0
  end

  test 'no Buzz permissions in the catalog or the role editor' do
    assert_equal User.builtin_permission_catalog, User.permission_catalog
    refute(User.all_permissions.any? { |permission| permission.start_with?('buzz.') })
    post login_path, params: { email: @admin.email, password: 'password' }
    get permissions_path
    assert_response :success
    refute_includes response.body, 'buzz.'
    refute_includes response.body, 'Team chat (Buzz)'
  end

  test 'no Buzz job is scheduled and no browser code is pinned' do
    recurring = YAML.load_file(Rails.root.join('config/recurring.yml'), aliases: true)
    classes = recurring.values.grep(Hash).flat_map { |jobs| jobs.values.grep(Hash).filter_map { |job| job['class'] } }
    assert_operator classes.size, :>, 0
    assert(classes.none? { |name| name.include?('Buzz') })
    refute(Rails.application.importmap.packages.keys.any? { |name| name.include?('buzz') })
  end
end
