# frozen_string_literal: true

require 'test_helper'

# AuthenticatedController runs Pundit's verify_authorized after every action, so a
# new action that forgets its permission check fails loudly instead of serving data.
class AuthorizationSafetyNetTest < ActionDispatch::IntegrationTest
  # Controllers allowed to opt out of verify_authorized, with the gate that replaces it.
  # Adding a controller here needs the same justification in a comment beside its skip.
  OPT_OUTS = {
    'employee_training_controller.rb' => 'lookups start from Current.user’s own assignments',
    'feedback_reports_controller.rb' => 'reads scoped to reported_by(Current.user) unless an attachment viewer',
    'home_controller.rb' => 'only the signed-out marketing landing page',
    'learning_controller.rb' => 'the signed-in account’s own learning journey (team still checks hr.read)',
    'next_things_controller.rb' => 'NextThings.for(Current.user) filters by the person’s own permissions',
    'notifications_controller.rb' => 'Notification.where(user_id: Current.user.id)',
    'receipts_controller.rb' => 'PurchaseReceipt.visible_to + ReceiptWorkflow ownership/review checks',
    'roadmap_controller.rb' => 'static product JSON; the module has no permission',
    'time_clock_controller.rb' => 'self-service punches on Current.user’s own shifts',
    'update_notices_controller.rb' => 'writes only the browser session',
    'workspaces_controller.rb' => 'the signed-in account’s own workspace deployment'
  }.freeze

  class UngatedProbeController < AuthenticatedController
    def index = head(:ok)
  end

  class GatedProbeController < AuthenticatedController
    def index
      authorize(:module, :dashboard_read?)
      head :ok
    end
  end

  setup do
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
    @user = users(:regular_user)
    post login_path, params: { email: @user.email, password: 'password' }
  end

  teardown { Current.reset }

  test 'an action that never authorizes raises instead of rendering' do
    with_routing do |set|
      set.draw do
        root to: 'home#index'
        post '/login', to: 'sessions#create', as: :login
        get '/probe/ungated', to: 'authorization_safety_net_test/ungated_probe#index'
        get '/probe/gated', to: 'authorization_safety_net_test/gated_probe#index'
      end
      post login_path, params: { email: @user.email, password: 'password' }
      get '/probe/gated'
      assert_response :ok
      assert_raises(Pundit::AuthorizationNotPerformedError) { get '/probe/ungated' }
    end
  end

  test 'in production an ungated action is reported and fails closed' do
    with_routing do |set|
      set.draw do
        root to: 'home#index'
        post '/login', to: 'sessions#create', as: :login
        get '/probe/ungated', to: 'authorization_safety_net_test/ungated_probe#index'
      end
      post login_path, params: { email: @user.email, password: 'password' }
      reported = []
      Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new('production'))
      Rails.error.stubs(:report).with { |error, **| reported << error.class }
      assert_raises(Pundit::AuthorizationNotPerformedError) { get '/probe/ungated' }
      assert_includes reported, Pundit::AuthorizationNotPerformedError
    end
  end

  test 'only documented controllers opt out of verify_authorized' do
    root = Rails.root.join('app/controllers')
    skipping = Dir[root.join('**/*_controller.rb')].select { |path| File.read(path).match?(/^\s*skip_after_action :verify_authorized/) }
      .map { |path| Pathname(path).relative_path_from(root).to_s }.sort
    assert_equal OPT_OUTS.keys.sort, skipping,
      'A controller skipping verify_authorized needs its own gate: prefer calling skip_authorization from that gate, ' \
      'or add it to OPT_OUTS with the reason.'
  end

  test 'a gate that denies inside the action still answers with its own response' do
    @user.update!(role: 'shift_leader')
    get ctrax_stock_index_path
    assert_redirected_to root_path
  end
end
