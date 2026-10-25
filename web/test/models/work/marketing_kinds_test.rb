# frozen_string_literal: true

require 'test_helper'

# The marketing kinds of the shared work-item table (#415): marketing_event and campaign_task. Fields, derived dates,
# transitions, per-kind permissions (marketing.*, Marketing on), workspace isolation, and that tasks are unaffected.
class MarketingWorkKindsTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = users(:regular_user)
    @manager = User.create!(tenant: @tenant, email: 'mkt-manager@example.com', role: 'manager', password: 'password123')
    @staff = User.create!(tenant: @tenant, email: 'mkt-staff@example.com', role: 'employee', password: 'password123')
    Current.user = @admin
    FeatureFlag.set(:marketing, true)
    @campaign = Marketing::Campaign.create!(name: 'Autumn tea', storefront_url: 'https://shop.example.com', topics: 'tea')
  end

  teardown { Current.reset }

  def event(**attrs)
    details = { 'starts_at' => '2026-11-07T10:00', 'ends_at' => '2026-11-08T15:00', 'time_zone' => 'Pacific Time (US & Canada)',
                'venue' => 'Riverside market' }.merge(attrs.delete(:details) || {})
    Work::Item.create!({ kind: 'marketing_event', title: 'Market stall', source: @campaign, details: details }.merge(attrs))
  end

  test 'the registry knows both marketing kinds with their statuses, fields and permissions' do
    kind = Work::Registry.fetch('marketing_event')
    assert_equal %w[planned confirmed held cancelled], kind.statuses
    assert_equal :span, kind.calendar
    assert_equal 'Marketing::WorkItemPolicy', kind.policy
    assert_equal({ read: 'marketing.read', write: 'marketing.write' }, kind.permissions)
    task = Work::Registry.fetch('campaign_task')
    assert_equal :due, task.calendar
    assert_equal %w[task marketing_event campaign_task], Work::Registry.calendar_kinds.map(&:key)
    assert_raises(ArgumentError) { Work::Registry.unregister('marketing_event') }
  end

  test 'an event keeps its local wall times and derives its local dates for the calendar' do
    item = event
    assert_equal 'planned', item.status
    assert_equal Date.new(2026, 11, 7), item.start_on
    assert_equal Date.new(2026, 11, 8), item.due_on
    starts = Marketing::WorkKinds.local_time(item, 'starts_at')
    assert_equal 'PST', starts.strftime('%Z')
    assert_equal 10, starts.hour
  end

  test 'event details are checked' do
    bad = Work::Item.new(kind: 'marketing_event', title: 'Bad', details: { 'starts_at' => '2026-11-07 10:00', 'ends_at' => '2026-11-07T09:00',
                                                                          'time_zone' => 'Mars/Olympus', 'channel' => 'fax' })
    refute bad.valid?
    messages = bad.errors[:details]
    assert_includes messages, 'Starts at is not a valid datetime'
    assert_includes messages, 'Time zone is not a known time zone'
    assert_includes messages, 'Channel is not a known channel'

    no_place = Work::Item.new(kind: 'marketing_event', title: 'Nowhere', details: { 'starts_at' => '2026-11-07T10:00', 'ends_at' => '2026-11-07T09:00', 'time_zone' => 'UTC' })
    refute no_place.valid?
    assert_includes no_place.errors[:details], 'Give a venue or a channel'
    assert_includes no_place.errors[:details], 'Ends at must be after the start'

    other = Tenant.create!(name: 'Other marketing', subdomain: 'mkt-other')
    foreign = Marketing::Campaign.unscoped.create!(tenant_id: other.id, name: 'Theirs', storefront_url: 'https://their.example.com', topics: 'x')
    stray = Work::Item.new(kind: 'marketing_event', title: 'Stray', source: foreign,
      details: { 'starts_at' => '2026-11-07T10:00', 'ends_at' => '2026-11-07T11:00', 'time_zone' => 'UTC', 'channel' => 'online', 'offer_id' => 999_999,
                 'location_id' => 'nowhere' })
    refute stray.valid?
    assert_includes stray.errors[:source], 'must be a campaign in this workspace'
    assert_includes stray.errors[:details], 'Offer was not found in this workspace'
    assert_includes stray.errors[:details], 'Location was not found in this workspace'
  end

  test 'event transitions follow the kind: writers confirm and hold, only managers cancel and reopen' do
    item = event
    writer = User.create!(tenant: @tenant, email: 'mkt-writer@example.com', role: 'reader', password: 'password123')
    writer.define_singleton_method(:can?) { |permission| %w[marketing.read marketing.write].include?(permission.to_s) }
    reader = User.create!(tenant: @tenant, email: 'mkt-reader@example.com', role: 'reader', password: 'password123')
    reader.define_singleton_method(:can?) { |permission| permission.to_s == 'marketing.read' }

    refute item.may_transition?('confirm', reader), 'read access cannot change status'
    assert_raises(Work::Item::TransitionRefused) { item.transition!('confirm', user: reader) }
    assert_raises(Work::Item::TransitionRefused) { item.transition!('reopen', user: @admin) }
    item.transition!('confirm', user: writer)
    assert_equal 'confirmed', item.reload.status
    assert item.started_at
    item.transition!('hold', user: @admin)
    assert_equal 'held', item.reload.status
    assert item.completed_at
    item.transition!('reopen', user: @admin)
    assert_equal 'planned', item.reload.status
    item.status = 'cancelled'
    refute item.save, 'status changes only through a transition'
    assert_equal %w[created transitioned transitioned transitioned], item.history.map(&:action)
    assert_equal 'marketing_event', item.history.first.item_kind
  end

  test 'a campaign task needs a campaign or an event, and its parent must be an event' do
    parent = event
    item = Work::Item.create!(kind: 'campaign_task', title: 'Print flyers', parent: parent, assignee_id: @admin.id.to_s, due_on: Date.new(2026, 11, 5))
    assert_equal 'todo', item.status
    assert_equal "/marketing/events/#{parent.id}#event-work", item.work_path
    refute Work::Item.new(kind: 'campaign_task', title: 'Loose').valid?
    assert Work::Item.new(kind: 'campaign_task', title: 'Campaign only', source: @campaign).valid?
    other_task = Projects::Task.create!(title: 'Ordinary task')
    wrong = Work::Item.new(kind: 'campaign_task', title: 'Wrong parent', parent_id: other_task.id)
    refute wrong.valid?
    assert_includes wrong.errors[:parent], 'must be a marketing event'

    assert_raises(Work::Item::TransitionRefused) { item.transition!('start', user: @manager) }
    item.transition!('start', user: @admin)
    assert_equal 'in_progress', item.reload.status
  end

  test 'marketing items are visible only with marketing access, only while Marketing is on, never to staff' do
    item = event(assignee_id: @admin.id.to_s)
    kind = Work::Registry.fetch('marketing_event')
    assert_equal [item.id], kind.visible_to(@admin, Work::Item.all).pluck(:id)
    assert_empty kind.visible_to(@manager, Work::Item.all).to_a, 'projects access is not marketing access'
    assert_empty kind.visible_to(@staff, Work::Item.all).to_a
    assert Marketing::WorkItemPolicy.new(@admin, item).update?
    refute Marketing::WorkItemPolicy.new(@manager, item).show?
    refute Work::ItemPolicy.for(@staff, item).show?

    FeatureFlag.set(:marketing, false)
    assert_empty kind.visible_to(@admin, Work::Item.all).to_a
    refute Marketing::WorkItemPolicy.new(@admin, item).show?

    task = Work::Registry.fetch('task')
    projects_task = Projects::Task.create!(title: 'Restock shelf')
    assert_equal [projects_task.id], task.visible_to(@manager, Work::Item.all).pluck(:id), 'task scope still filters its own kind'
  end

  test 'marketing items stay in their workspace' do
    item = event
    other = Tenant.create!(name: 'Other marketing two', subdomain: 'mkt-other-two')
    Current.tenant = other
    assert_nil Work::Item.find_by(id: item.id)
    outsider = User.create!(tenant: other, email: 'mkt-outsider@example.com', role: 'admin', password: 'password123')
    refute Marketing::WorkItemPolicy.new(outsider, item).show?
    assert_empty Work::Registry.fetch('marketing_event').visible_to(outsider, Work::Item.unscoped).to_a
  end

  test 'marketing items never show up as tasks' do
    project = Projects::Project.create!(name: 'Store refresh')
    Projects::Task.create!(title: 'Paint', project: project)
    before = { count: Projects::Task.count, ids: Projects::Task.pluck(:id), counts: project.reload.task_counts, overdue: Projects::Task.overdue.count }
    parent = event
    Work::Item.create!(kind: 'campaign_task', title: 'Flyers', parent: parent, due_on: 3.days.ago.to_date)
    Work::Item.create!(kind: 'campaign_task', title: 'Posters', source: @campaign, due_on: Date.current)

    assert_equal 3, Work::Item.where(kind: %w[marketing_event campaign_task]).count
    assert_equal before[:count], Projects::Task.count
    assert_equal before[:ids], Projects::Task.pluck(:id)
    assert_equal before[:counts], Projects::Project.find(project.id).task_counts
    assert_equal before[:overdue], Projects::Task.overdue.count
    assert_raises(ActiveRecord::RecordNotFound) { Projects::Task.find(parent.id) }
    assert_equal Projects::Task.pluck(:id).sort, Projects::TaskPolicy::Scope.new(@admin, Projects::Task.all).resolve.pluck(:id).sort
    assert_equal Projects::Task.pluck(:id).sort, Projects::TaskPolicy::Scope.new(@admin, Work::Item.all).resolve.pluck(:id).sort
  end
end
