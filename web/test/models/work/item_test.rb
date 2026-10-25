# frozen_string_literal: true

require 'test_helper'

# The shared work-item core (#407): kind registry, per-kind fields and transitions, append-only history, tenant
# isolation and permissions. A throwaway 'errand' kind stands in for the kinds later phases add.
class WorkItemTest < ActiveSupport::TestCase
  ERRAND = Work::Kind.new(
    key: 'errand', label: 'Errand', statuses: %w[open underway closed], initial_status: 'open', done_statuses: %w[closed],
    started_statuses: %w[underway],
    transitions: {
      'begin' => { from: %w[open], to: 'underway', who: :assignee },
      'close' => { from: %w[open underway], to: 'closed', who: :manager }
    },
    fields: { 'venue' => { type: :string, max: 40, required: true }, 'seats' => { type: :integer }, 'link' => { type: :url },
              'on' => { type: :date } },
    permissions: { read: 'projects.read', write: 'projects.write', self_service: 'tasks.self' }
  )

  setup do
    Work::Registry.register(ERRAND)
    @tenant = tenants(:default_tenant)
    @other_tenant = Tenant.create!(name: 'Other work workspace', subdomain: 'work-item-other')
    Current.tenant = @tenant
    @manager = User.create!(tenant: @tenant, email: 'work-manager@example.com', role: 'manager', password: 'password123')
    @staff = User.create!(tenant: @tenant, email: 'work-staff@example.com', role: 'employee', password: 'password123')
    @cashier = User.create!(tenant: @tenant, email: 'work-cashier@example.com', role: 'cashier', password: 'password123')
    Current.user = @manager
  end

  teardown do
    Work::Registry.unregister('errand')
    Current.reset
  end

  def errand(**attrs)
    Work::Item.create!({ kind: 'errand', title: 'Pick up flyers', details: { 'venue' => 'Print shop' } }.merge(attrs))
  end

  test 'the registry knows task, reads its transitions from the task state machine, and refuses unknown kinds' do
    task = Work::Registry.fetch('task')
    assert_equal 'Projects::Task', task.model
    assert_equal %w[todo in_progress blocked done], task.statuses
    assert_equal Projects::Task.aasm.events.map { |event| event.name.to_s }.sort, task.transition_table.keys.sort
    assert_equal 'in_progress', task.transition('start')[:to]
    assert task.allows?('finish', 'todo')
    refute task.allows?('unstart', 'done')
    assert_raises(Work::Registry::UnknownKind) { Work::Registry.fetch('nope') }
    assert_raises(ArgumentError) { Work::Registry.register(ERRAND) }
    assert_raises(ArgumentError) { Work::Registry.unregister('task') }

    item = Work::Item.new(kind: 'nope', title: 'Stray')
    refute item.valid?
    assert_includes item.errors[:kind], 'is not a known kind of work'
  end

  test 'kind-specific details are checked against the kind field list' do
    item = errand
    assert_equal 'open', item.status
    assert_equal({ 'venue' => 'Print shop' }, item.reload.details)

    bad = Work::Item.new(kind: 'errand', title: 'Bad', details: { 'venue' => '', 'seats' => 'many', 'link' => 'http://x', 'on' => '2026-13-40', 'extra' => 1 })
    refute bad.valid?
    messages = bad.errors[:details]
    ['Venue is required', 'Seats is not a valid integer', 'Link is not a valid url', 'On is not a valid date', 'has unknown fields: extra'].each do |message|
      assert_includes messages, message
    end
    refute Work::Item.new(kind: 'errand', title: 'Long', details: { 'venue' => 'x' * 41 }).valid?
    assert Work::Item.new(kind: 'errand', title: 'Fine', details: { 'venue' => 'Hall', 'seats' => 4, 'link' => 'https://example.com/e', 'on' => '2026-11-02' }).valid?
  end

  test 'status changes only through an allowed transition, by someone allowed to fire it' do
    item = errand(assignee_id: @staff.id.to_s)
    item.status = 'closed'
    refute item.save
    assert_includes item.errors[:status], 'changes only through a transition'

    item.reload
    refute item.may_transition?('begin', @cashier), 'no project permission'
    assert item.may_transition?('begin', @staff), 'the assignee may begin'
    refute item.may_transition?('close', @staff), 'only a manager may close'
    assert_raises(Work::Item::TransitionRefused) { item.transition!('close', user: @staff) }
    assert_equal 'open', item.reload.status

    item.transition!('begin', user: @staff)
    assert_equal 'underway', item.status
    assert item.started_at
    error = assert_raises(Work::Item::TransitionRefused) { item.transition!('begin', user: @staff) }
    assert_equal 'Cannot begin a underway errand.', error.message
    assert_raises(Work::Item::TransitionRefused) { item.transition!('fly', user: @manager) }

    item.transition!('close', user: @manager, note: 'Done early')
    assert_equal 'closed', item.status
    assert item.completed_at
    assert_equal 'errand_transitioned', ActivityLog.where(subject_type: 'Work::Item', subject_id: item.id.to_s).last.action
  end

  test 'history records who did what and is append-only' do
    item = errand(assignee_id: @staff.id.to_s)
    item.update!(due_on: Date.new(2026, 11, 5))
    item.update!(title: 'Pick up posters', details: { 'venue' => 'Print shop', 'seats' => 2 })
    item.transition!('begin', user: @staff)
    item.update!(position: 3) # board order is not history

    events = item.history.to_a
    assert_equal %w[created rescheduled updated transitioned], events.map(&:action)
    assert_equal [@manager.id, @manager.id, @manager.id, @staff.id], events.map(&:actor_id)
    assert_equal [nil, 'open'], [events.first.from_status, events.first.to_status]
    assert_equal ['open', 'underway', 'begin'], [events.last.from_status, events.last.to_status, events.last.transition]
    assert_equal [nil, '2026-11-05'], events.second.field_changes['due_on']
    assert_equal ['Pick up flyers', 'Pick up posters'], events.third.field_changes['title']
    assert(events.all? { |event| event.item_kind == 'errand' && event.tenant_id == @tenant.id })

    event = events.first
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(action: 'deleted') }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.delete }
    refute event.destroy
    assert Work::ItemEvent.exists?(event.id)

    item.destroy!
    assert_equal 'deleted', Work::ItemEvent.for_item(item).timeline.last.action, 'history outlives the item'
  end

  test 'items and history stay inside their workspace' do
    mine = errand
    Current.set(user: nil, tenant: @other_tenant) do
      theirs = Work::Item.create!(kind: 'errand', title: 'Their errand', details: { 'venue' => 'Elsewhere' })
      assert_equal [theirs.id], Work::Item.of_kind('errand').pluck(:id)
      assert_equal [theirs.id], Work::ItemEvent.distinct.pluck(:work_item_id)
      assert_equal 'system', theirs.history.sole.actor_name
      refute Work::Item.exists?(mine.id)
    end
    Current.user = @manager # Current.set restores tenant before user; put both back explicitly
    assert_equal [mine.id], Work::Item.of_kind('errand').pluck(:id)

    outsider = User.create!(tenant: @other_tenant, email: 'work-outsider@example.com', role: 'manager', password: 'password123')
    refute Work::Item.new(kind: 'errand', title: 'X', details: { 'venue' => 'Y' }, assignee_id: outsider.id.to_s).valid?
    refute Work::ItemPolicy.new(outsider, mine).show?
    refute mine.may_transition?('close', outsider)
    Current.tenant = @other_tenant
    foreign_parent = Work::Item.create!(kind: 'errand', title: 'P', details: { 'venue' => 'Z' })
    Current.tenant = @tenant
    child = Work::Item.new(kind: 'errand', title: 'Child', details: { 'venue' => 'Z' }, parent_id: foreign_parent.id)
    refute child.valid?
    assert_includes child.errors[:parent], 'was not found'
  end

  test 'default policy follows the kind permissions, with staff limited to their own items' do
    own = errand(assignee_id: @staff.id.to_s)
    other = errand(title: 'Not theirs')
    assert Work::ItemPolicy.new(@manager, other).update?
    assert Work::ItemPolicy.new(@manager, other).create?
    refute Work::ItemPolicy.new(@cashier, other).show?
    assert Work::ItemPolicy.new(@staff, own).update?
    refute Work::ItemPolicy.new(@staff, other).show?
    refute Work::ItemPolicy.new(@staff, own).create?

    scope = ->(user) { Work::ItemPolicy::Scope.new(user, Work::Item.unscoped, kind: 'errand').resolve.pluck(:id).sort }
    assert_equal [own.id, other.id].sort, scope.call(@manager)
    assert_equal [own.id], scope.call(@staff)
    assert_empty scope.call(@cashier)
  end

  test 'a task is a work item: readable through Work::Item, written only through Projects::Task' do
    task = Projects::Task.create!(title: 'Restock shelf', assignee: @staff)
    assert_equal 'task', task.kind
    item = Work::Item.find(task.id)
    assert_equal 'Restock shelf', item.title
    assert_equal task, item.specific
    assert_kind_of Projects::TaskPolicy, Work::ItemPolicy.for(@manager, item)
    assert_equal "/projects/tasks/#{task.id}", item.work_path

    item.title = 'Renamed behind the task rules'
    refute item.save
    assert_includes item.errors[:base], 'Tasks are saved through Projects::Task'

    errand_row = errand
    refute Projects::Task.exists?(errand_row.id), 'tasks never see other kinds'
    assert_equal [task.id], Projects::TaskPolicy::Scope.new(@manager, Work::Item.unscoped).resolve.pluck(:id)
  end

  test 'a task transition through Work::Item keeps the task rules and writes history' do
    blocker = Projects::Task.create!(title: 'Order stock')
    task = Projects::Task.create!(title: 'Shelve stock', assignee: @staff)
    task.dependencies.create!(blocker: blocker)
    item = Work::Item.find(task.id)

    error = assert_raises(Work::Item::TransitionRefused) { item.transition!('start', user: @staff) }
    assert_equal 'Waiting on Order stock.', error.message
    refute item.may_transition?('start', @cashier)

    blocker.finish!
    item.transition!('start', user: @staff)
    assert_equal 'in_progress', task.reload.status
    assert task.started_at
    item.transition!('block', user: @staff, note: 'Shelf broken')
    assert_equal 'Shelf broken', task.reload.blocked_reason

    events = task.history.to_a
    assert_equal %w[created transitioned transitioned], events.map(&:action)
    assert_equal [%w[todo in_progress start], %w[in_progress blocked block]],
      events.drop(1).map { |event| [event.from_status, event.to_status, event.transition] }
    assert_equal 'Shelf broken', events.last.note
    assert_equal 'task_transitioned', ActivityLog.where(subject_id: task.id.to_s).last.action
  end
end
