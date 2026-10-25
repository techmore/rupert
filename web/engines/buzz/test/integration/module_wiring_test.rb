# frozen_string_literal: true

require_relative '../test_helper'

# With the module on: its page is in the rail (Team -> People), its permissions
# are on the Permissions screen, its routes answer before the old redirects, and
# nothing else about Rupert changes (team chat, recurring jobs).
class BuzzModuleWiringTest < ActionDispatch::IntegrationTest
  setup do
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
    @tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
  end

  def sign_in(user, password = 'password')
    post login_path, params: { email: user.email, password: password }
  end

  test 'the switch is on and the module is loaded' do
    assert Rails.application.config.x.buzz_enabled
    assert defined?(Buzz::Engine)
  end

  test 'the module code eager-loads cleanly' do
    %w[models services jobs controllers].each { |dir| Rails.autoloaders.main.eager_load_dir(Buzz::Engine.root.join('app', dir).to_s) }
    assert Buzz::Chat
    assert_equal 'buzz_messages', Buzz::Message.table_name
    assert_equal 'buzz_chat_reads', Buzz::ChatRead.table_name
  end

  test 'one registry entry, in Team -> People, for people with buzz.read' do
    entry = ModuleRegistry.find('buzz')
    assert_equal 'Buzz', entry.name
    assert_equal 'team', ModuleRegistry.area_key_for('buzz')
    people = ModuleRegistry.areas.find { |area| area[:key] == 'team' }[:groups].find { |group| group[:name] == 'People' }
    assert_includes people[:modules], 'buzz'
    assert_equal 1, ModuleRegistry.all.count { |candidate| candidate.key == 'buzz' }

    refute_includes ModuleRegistry.nav_for(@admin).map(&:key), 'buzz', 'no role has buzz.read by default'
    @admin.update_permission_overrides!((User::ROLE_PERMISSIONS.fetch('admin') + ['buzz.read']).uniq)
    assert_includes ModuleRegistry.nav_for(@admin.reload).map(&:key), 'buzz'
  end

  test 'the rail links the page and marks it current' do
    @admin.update_permission_overrides!((User::ROLE_PERMISSIONS.fetch('admin') + ['buzz.read', 'hr.read']).uniq)
    sign_in(@admin)
    get buzz_chat_path
    assert_response :success
    assert_select "nav[aria-label=Module] a[href='#{buzz_chat_path}'][aria-current=page]", text: 'Buzz'
    assert_select 'h1', 'Buzz'
  end

  test 'its permissions are on the Permissions screen and can be granted' do
    group = User.permission_catalog.find { |candidate| candidate[:area] == 'Team chat (Buzz)' }
    assert_equal ['buzz.read', 'buzz.post'], group[:permissions]
    assert_includes User.all_permissions, 'buzz.post'
    User::ROLE_PERMISSIONS.each_value { |list| refute_includes list, 'buzz.read' }

    @admin.update!(role: 'super_admin')
    sign_in(@admin)
    get permissions_path
    assert_response :success
    assert_includes response.body, 'buzz.read'
  end

  test 'its routes answer first; /admin/buzz still leads to team chat' do
    get '/buzz'
    assert_redirected_to '/buzz/chat'
    get '/admin/buzz'
    assert_redirected_to '/chat'
    get '/buzz/chat'
    assert_redirected_to login_path, 'the module page, behind sign-in, not the old redirect'
  end

  test 'team chat and the recurring schedule are untouched' do
    recurring = YAML.load_file(Rails.root.join('config/recurring.yml'), aliases: true)
    classes = recurring.values.grep(Hash).flat_map { |jobs| jobs.values.grep(Hash).filter_map { |job| job['class'] } }
    assert(classes.none? { |name| name.start_with?('Buzz') })

    @admin.update!(role: 'super_admin')
    sign_in(@admin)
    get team_chat_path
    follow_redirect! while response.redirect?
    assert_response :success
    assert_equal '/chat/admins', path
  end

  test 'the browser controller is pinned for the page' do
    assert Rails.application.importmap.packages.key?('controllers/buzz_chat_controller')
  end
end
