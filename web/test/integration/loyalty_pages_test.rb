# frozen_string_literal: true

require 'test_helper'
require_relative '../support/fake_square_loyalty'

class LoyaltyPagesTest < ActionDispatch::IntegrationTest
  include FakeSquareLoyalty
  include ActiveJob::TestHelper

  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    SquareClient.stubs(:token).returns('synthetic-loyalty-token')
    SquareClient.stubs(:environment).returns('production')
    @customer = Core::Customer.create!(source: 'square', external_id: 'SQCUST-1', first_name: 'Mira', last_name: 'Leaf', email: 'mira@example.test')
    @order = Core::Order.new(source: 'square', source_order_id: 'ORDER-1', occurred_at: 3.days.ago, gross_cents: 2_500, currency: 'USD', customer_id: @customer.id)
    @order.aasm.current_state = :paid
    @order.save!
  end

  teardown { Current.reset }

  def mirror!
    Current.user = @user
    stub_square_loyalty(accounts: [fake_account('acct-1', customer_id: 'SQCUST-1', balance: 60, lifetime: 210),
                                   fake_account('acct-2', customer_id: 'SQCUST-ELSEWHERE', balance: 3)],
      events: [[fake_event('ev-2', account: 'acct-1', type: 'ACCUMULATE_POINTS', at: '2026-10-30T15:00:00Z', points: 12, order_id: 'ORDER-1'),
                fake_event('ev-1', account: 'acct-1', type: 'REDEEM_REWARD', at: '2026-10-29T15:00:00Z', order_id: 'ORDER-1')]],
      promotions: [{ 'id' => 'promo-1', 'name' => 'Double leaves weekend', 'status' => 'ACTIVE', 'loyalty_program_id' => PROGRAM_ID,
                     'incentive' => { 'type' => 'POINTS_MULTIPLIER', 'points_multiplier_data' => { 'points_multiplier' => 2, 'multiplier' => '2.000' } },
                     'available_time' => { 'start_date' => '2026-11-01', 'time_periods' => [] }, 'created_at' => '2026-10-01T00:00:00Z' }])
    SquareLoyaltyImport.new.call(apply: true)
  end

  test 'loyalty page shows the program, rewards, promotions and members with Square as a source pill' do
    mirror!
    sign_in @user
    get loyalty_path
    assert_response :success
    assert_select 'h1', 'Loyalty'
    assert_select 'span.pill-taupe', 'Square'
    assert_includes response.body, '1 Leaf per $1.00 spent'
    assert_includes response.body, 'Leaves expire 12 months after they are earned'
    assert_includes response.body, '$5 off'
    assert_includes response.body, 'Double leaves weekend'
    assert_includes response.body, '2× points'
    assert_select 'tbody tr', 2
    assert_select 'tbody tr:first-child a[href=?]', customer_path(@customer, anchor: 'loyalty'), text: 'Mira Leaf'
    assert_includes response.body, 'Not in customers'
    assert_not_includes response.body, '+15555550123'

    get loyalty_path(q: 'Mira')
    assert_select 'tbody tr', 1
    get loyalty_path(show: 'redeemable')
    assert_select 'tbody tr', 1
    get loyalty_path(show: 'unlinked')
    assert_select 'tbody tr', 1
    assert_includes response.body, 'Not in customers'
    get loyalty_path(sort: 'balance', dir: 'asc')
    assert_select 'tbody tr:first-child td.num', '3'
  end

  test 'customer page shows points, rewards available and recent activity linked to orders' do
    mirror!
    sign_in @user
    get customer_path(@customer)
    assert_response :success
    assert_select 'section#loyalty' do
      assert_select '.stat-value', '60'
      assert_select '.stat-value', '210'
      assert_includes css_select('section#loyalty').text, '$5 off'
      assert_includes css_select('section#loyalty').text, '90 Leaves to $20 off'
      assert_select 'a[href=?]', order_path(@order)
      assert_select '.pill-fern', 'Earned'
      assert_includes css_select('section#loyalty').text, '+12'
    end
  end

  test 'customers without loyalty data show no section; Square customers without an account say so' do
    manual = Core::Customer.create!(source: 'manual', external_id: 'manual-loyalty', first_name: 'Hand')
    sign_in @user
    get customer_path(manual)
    assert_select 'section#loyalty', 0
    mirror!
    other = Core::Customer.create!(source: 'square', external_id: 'SQCUST-NEW', first_name: 'New')
    get customer_path(other)
    assert_select 'section#loyalty', 1
    assert_includes response.body, 'Not a loyalty member'
  end

  test 'empty page offers a sync, and Sync now only queues a read-only job' do
    sign_in @user
    get loyalty_path
    assert_response :success
    assert_includes response.body, 'No loyalty data yet'
    SquareClient.stubs(:configured?).returns(true)
    assert_enqueued_with(job: SquareLoyaltySyncJob, args: [Current.tenant.id, { actor_id: @user.id }]) do
      post sync_loyalty_path
    end
    assert_redirected_to loyalty_path
  end

  test 'staff without customer access cannot open loyalty; readers cannot sync' do
    Current.user = @user
    leader = User.create!(tenant: Current.tenant, email: 'loyalty-leader@example.test', password: 'password123', role: 'shift_leader')
    sign_in leader
    get loyalty_path
    assert_response :redirect
    delete logout_path
    reader = User.create!(tenant: Current.tenant, email: 'loyalty-page-reader@example.test', password: 'password123', role: 'reader')
    sign_in reader
    get loyalty_path
    assert_response :success
    assert_select 'form[action=?]', sync_loyalty_path, 0
    assert_no_enqueued_jobs(only: SquareLoyaltySyncJob) { post sync_loyalty_path }
  end
end
