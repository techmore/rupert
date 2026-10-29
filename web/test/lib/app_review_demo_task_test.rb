# frozen_string_literal: true

require 'test_helper'
require 'rake'

class AppReviewDemoTaskTest < ActiveSupport::TestCase
  PASSWORD = 'correct-horse-battery-9'

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?('rupert:app_review_demo')
    @task = Rake::Task['rupert:app_review_demo']
    @task.reenable
  end

  teardown do
    Current.reset
  end

  def run_task(env)
    output = nil
    with_env(env) { output = capture_io { @task.execute }.join }
    output
  end

  def with_env(values)
    previous = values.to_h { |key, _| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  def demo_tenant = Tenant.find_by!(subdomain: AppReviewDemo::SUBDOMAIN)

  def in_demo(&) = Current.set(tenant: demo_tenant, &)

  test 'refuses to run without a long enough password and creates nothing' do
    assert_raises(SystemExit) { capture_io { with_env('REVIEW_PASSWORD' => nil) { @task.execute } } }
    assert_raises(SystemExit) { capture_io { with_env('REVIEW_PASSWORD' => 'short') { @task.execute } } }
    assert_nil Tenant.find_by(subdomain: AppReviewDemo::SUBDOMAIN)
    assert_nil User.find_by(email: AppReviewDemo::EMAIL)
  end

  test 'builds a fictional workspace with an admin reviewer and never prints the password' do
    output = run_task('REVIEW_PASSWORD' => PASSWORD, 'REVIEW_DEMO_RESET' => nil)

    assert_not_includes output, PASSWORD
    tenant = demo_tenant
    assert_equal AppReviewDemo::NAME, tenant.name
    assert_equal 'active', tenant.status

    reviewer = User.find_by!(email: AppReviewDemo::EMAIL)
    assert_equal tenant.id, reviewer.tenant_id
    assert_equal 'admin', reviewer.role
    assert reviewer.active?
    assert reviewer.authenticate(PASSWORD)
    assert_not User.where(tenant_id: tenant.id, role: 'super_admin').exists?

    in_demo do
      assert_equal 2, Location.count
      assert_equal AppReviewDemo::CATALOG.size, ShopifyVariant.count
      assert_equal AppReviewDemo::CATALOG.size * 2, InventoryLevel.count
      assert StockAlert.open.exists?
      assert Core::Order.count.positive?
      assert_equal Core::Order.count, Core::Order.where(status: 'paid').count
      assert Core::Order.all.all? { |order| order.gross_cents == order.order_lines.sum(:line_cents) + order.tax_cents }
      assert_operator Core::Order.maximum(:occurred_at), :<=, Time.current
      count = InventoryCount.find_by!(note: 'Front wall · weekly shelf count')
      assert count.draft?
      assert_equal 3, count.items.count
      assert_equal 3, Projects::Task.where(assignee_id: reviewer.id.to_s).count
      assert_equal 4, Notification.where(user_id: reviewer.id).count
      room = TeamChat::Room.find_by!(slug: 'shop-floor')
      assert_equal AppReviewDemo::CHAT.size, room.messages.count
      assert_equal 'mentions', room.assistant_mode
      assert TeamChat::Membership.where(user_id: reviewer.id).order(updated_at: :desc).first.room == room
    end

    # Every row the task wrote carries the demo workspace's id.
    [Location, ShopifyProduct, ShopifyVariant, InventoryLevel, Core::Order, Core::OrderLine, Notification, TeamChat::Message].each do |model|
      assert model.unscoped.where(tenant_id: tenant.id).exists?, "#{model} has no demo rows"
    end
  end

  test 'running again adds nothing and keeps the password it is given' do
    run_task('REVIEW_PASSWORD' => PASSWORD, 'REVIEW_DEMO_RESET' => nil)
    counts = -> { in_demo { [User.where(tenant_id: demo_tenant.id).count, Location.count, ShopifyVariant.count, InventoryLevel.count, Core::Order.count, Core::OrderLine.count, InventoryCountItem.count, Projects::Task.count, Notification.count, TeamChat::Message.count, TeamChat::Room.count] } }
    before = counts.call

    run_task('REVIEW_PASSWORD' => "#{PASSWORD}-new", 'REVIEW_DEMO_RESET' => nil)

    assert_equal before, counts.call
    assert_equal 1, Tenant.where(subdomain: AppReviewDemo::SUBDOMAIN).count
    assert User.find_by!(email: AppReviewDemo::EMAIL).authenticate("#{PASSWORD}-new")
  end

  test 'reset rebuilds only the demo workspace and leaves other workspaces alone' do
    other = create_workspace('Someone else', current: false, status: 'active')
    other_order = Current.set(tenant: other) do
      Core::Order.create!(source: 'manual', source_order_id: 'keep-me', occurred_at: 1.day.ago, gross_cents: 1_000).tap(&:mark_paid!)
    end
    other_location = Current.set(tenant: other) { Location.create!(source: 'shopify', externalId: "#{AppReviewDemo::KEY}-shop", name: 'Theirs') }

    run_task('REVIEW_PASSWORD' => PASSWORD, 'REVIEW_DEMO_RESET' => nil)
    in_demo { Core::Order.first.update_columns(gross_cents: 1) }
    run_task('REVIEW_PASSWORD' => PASSWORD, 'REVIEW_DEMO_RESET' => '1')

    assert Core::Order.unscoped.exists?(other_order.id)
    assert Location.unscoped.exists?(other_location.id)
    assert_equal 'Theirs', Location.unscoped.find(other_location.id).name
    in_demo do
      assert_not Core::Order.exists?(gross_cents: 1)
      assert_equal 2, Location.count
      assert_equal AppReviewDemo::CHAT.size, TeamChat::Room.find_by!(slug: 'shop-floor').messages.count
    end
    assert User.find_by!(email: AppReviewDemo::EMAIL).authenticate(PASSWORD)
  end

  test 'refuses an existing workspace or account that is not the demo one' do
    Tenant.create!(name: 'A real shop', subdomain: AppReviewDemo::SUBDOMAIN, status: 'active')
    assert_raises(SystemExit) { capture_io { with_env('REVIEW_PASSWORD' => PASSWORD) { @task.execute } } }
    assert_nil User.find_by(email: AppReviewDemo::EMAIL)
  end

  test 'refuses to move the review account out of another workspace' do
    User.create!(email: AppReviewDemo::EMAIL, password: 'another-password', tenant: tenants(:default_tenant), role: 'admin')
    assert_raises(SystemExit) { capture_io { with_env('REVIEW_PASSWORD' => PASSWORD) { @task.execute } } }
    assert_equal tenants(:default_tenant).id, User.find_by!(email: AppReviewDemo::EMAIL).tenant_id
  end
end
