# frozen_string_literal: true

require 'test_helper'

# Marketing events on screen (#415): add, open, edit, change status, add campaign work, count results from stored
# orders and enter a tally, with marketing permissions and the Marketing switch enforced.
class MarketingEventsFlowTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    FeatureFlag.set(:marketing, true)
    @campaign = Marketing::Campaign.create!(name: 'Holiday', storefront_url: 'https://shop.example.com', topics: 'gifts')
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  def event_params(**overrides)
    { title: 'Holiday market', starts_at: '2026-12-05T10:00', ends_at: '2026-12-05T16:00', time_zone: 'Eastern Time (US & Canada)',
      venue: 'Town hall', channel: 'market', campaign_id: @campaign.id, assignee_id: users(:regular_user).id }.merge(overrides)
  end

  test 'an operator adds an event, works it and records its results' do
    get marketing_events_path
    assert_response :success
    assert_select 'h1', 'Events'
    assert_select '.empty-state'
    get new_marketing_event_path
    assert_response :success

    post marketing_events_path, params: { event: event_params(ends_at: '2026-12-05T09:00') }
    assert_response :unprocessable_content
    assert_select '[role=alert]', /Ends at must be after the start/

    post marketing_events_path, params: { event: event_params }
    event = Work::Item.of_kind('marketing_event').last
    assert_redirected_to marketing_event_path(event)
    assert_equal [Date.new(2026, 12, 5), Date.new(2026, 12, 5), @campaign], [event.start_on, event.due_on, event.source]
    follow_redirect!
    assert_select 'h1', 'Holiday market'
    assert_includes response.body, 'Dec 5, 2026, 10:00 AM – 4:00 PM EST'

    get edit_marketing_event_path(event)
    assert_response :success
    assert_select "input[name='event[starts_at]'][value='2026-12-05T10:00']"
    patch marketing_event_path(event), params: { event: event_params(venue: 'Library lawn') }
    assert_equal 'Library lawn', event.reload.details['venue']

    post transition_marketing_event_path(event), params: { event: 'confirm' }
    assert_equal 'confirmed', event.reload.status
    post transition_marketing_event_path(event), params: { event: 'reopen' }
    assert_equal 'Cannot reopen a confirmed marketing event.', flash[:alert]

    post marketing_event_work_items_path(event), params: { work_item: { title: 'Print flyers', due_on: '2026-12-01' } }
    work = Work::Item.of_kind('campaign_task').last
    assert_equal [event.id, @campaign], [work.parent_id, work.source]
    post transition_marketing_event_work_item_path(event, work), params: { event: 'finish' }
    assert_equal 'done', work.reload.status

    Core::Order.create!(source: 'shopify', source_order_id: 'mkt-1', occurred_at: Time.zone.parse('2026-12-05 11:00'), gross_cents: 4200,
      tax_cents: 200, discount_codes: ['HOLIDAY'])
    post count_marketing_event_results_path(event), params: { code: 'holiday', from: '2026-12-05T10:00', to: '2026-12-05T16:00' }
    assert_equal 'Counted 1 order from stored orders.', flash[:notice]
    post marketing_event_results_path(event), params: { result: { code: 'FLYER', redemptions: '7', revenue: '140.50', summary: 'Paper tally' } }
    assert_equal 'Result saved.', flash[:notice]
    assert_equal [['HOLIDAY', 'stored_orders', 1, 4000], ['FLYER', 'manual', 7, 14_050]].sort,
      Marketing::Result.where(work_item_id: event.id).pluck(:code, :basis, :redemptions, :revenue_cents).sort

    get marketing_event_path(event)
    assert_select '#event-results td', text: '$40.00'
    assert_select '#event-work', /Print flyers/
    assert_includes response.body, 'Status changed'

    manual = Marketing::Result.find_by(code: 'FLYER')
    delete marketing_event_result_path(event, manual)
    refute Marketing::Result.exists?(manual.id)
  end

  test 'people without marketing access, and workspaces with Marketing off, cannot open events' do
    event = Work::Item.create!(kind: 'marketing_event', title: 'Secret launch',
      details: { 'starts_at' => '2026-12-05T10:00', 'ends_at' => '2026-12-05T11:00', 'time_zone' => 'UTC', 'channel' => 'online' })
    manager = User.create!(tenant: @tenant, email: 'events-manager@example.com', role: 'manager', password: 'password123')
    delete logout_path
    post login_path, params: { email: manager.email, password: 'password123' }
    get marketing_event_path(event)
    refute response.successful?
    refute_includes response.body, 'Secret launch'

    delete logout_path
    post login_path, params: { email: 'admin@example.com', password: 'password' }
    FeatureFlag.set(:marketing, false)
    get marketing_event_path(event)
    assert_response :not_found
  end

  test 'another workspace cannot open an event' do
    other = Tenant.create!(name: 'Other events', subdomain: 'events-other')
    foreign = Work::Item.unscoped.create!(tenant_id: other.id, kind: 'marketing_event', title: 'Their market',
      details: { 'starts_at' => '2026-12-05T10:00', 'ends_at' => '2026-12-05T11:00', 'time_zone' => 'UTC', 'channel' => 'online' })
    get marketing_event_path(foreign)
    assert_response :not_found
  end
end
