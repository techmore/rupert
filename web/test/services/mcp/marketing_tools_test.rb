# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/marketing_setup'

class MarketingToolsTest < ActiveSupport::TestCase
  include MarketingSetup

  setup do
    Current.tenant = tenants(:default_tenant)
    setup_marketing
    @actor.update!(name: 'Sam Marketer')
    @token = TeamChat::Token.new(@actor)
    @influencer = Marketing::Influencer.create!(name: 'Tea Creator', platform: 'YouTube', handle: 'tea-creator', topics: 'herbal tea',
      profile_url: 'https://www.youtube.com/@tea-creator', stage: 'interested', owner_id: @actor.id, next_follow_up_at: 1.day.ago,
      contact_email: 'creator@example.org', shipping_details: 'PRIVATE ADDRESS 123 Test Lane', private_notes: 'PRIVATE CONTACT NOTES')
    Marketing::Influencer.create!(name: 'Quiet Prospect', stage: 'prospect')
    @engagement = @influencer.engagements.create!(campaign: @campaign, title: 'Tea sampler collaboration', status: 'active',
      destination_url: "#{@campaign.storefront_url}/tea", deliverables: 'One honest post', due_at: 3.days.from_now)
  end

  teardown { Current.reset }

  def records(args) = Mcp::Tools::MarketingRecords.new(token: @token).call(args)

  def gift(status:, shipped_at: nil, items: [['Calm Gummies 30ct', 'CALM-30', 2, 1500]])
    gift = Marketing::ProductGift.new(engagement: @engagement, status: status, currency: 'USD', shipping_cost_cents: 850,
      shipped_at: shipped_at, carrier: 'USPS', tracking_number: 'TRACK-SECRET-1', shipping_details: 'PRIVATE ADDRESS 123 Test Lane')
    gift.workflow_checked = true
    gift.save!
    items.each_with_index do |(name, sku, quantity, cost), index|
      item = gift.items.new(source_variant_id: "variant-#{gift.id}-#{index}", product_name: name, sku: sku, quantity: quantity, unit_cost_cents: cost)
      item.workflow_checked = true
      item.save!
    end
    gift
  end

  def creator_discount
    offer = Marketing::Offer.create!(engagement: @engagement, code: 'CREATOR15', terms: '15% off; one use per customer',
      destination_url: @engagement.destination_url, starts_at: 1.hour.ago, ends_at: 5.days.from_now)
    input = Marketing::ShopifyDiscountTerms.build({ code: 'CREATOR15', kind: 'percentage', value: '15', usage_limit: '100',
                                                    once_per_customer: '1', starts_at: 1.hour.ago.iso8601, ends_at: 5.days.from_now.iso8601 }, title: 'Creator code')
    Marketing::ShopifyDiscount.create!(offer: offer, shop_domain: 'test-shop.myshopify.com', shop_id: 'gid://shopify/Shop/1', currency: 'USD',
      request_key: SecureRandom.hex(8), request_json: JSON.generate(input), status: 'created', remote_status: 'ACTIVE',
      remote_id: 'gid://shopify/DiscountCodeNode/42', checked_at: Time.current)
  end

  test 'campaigns, communities and offers list with counts' do
    campaigns = records('kind' => 'campaigns')
    row = campaigns.data[:rows].first
    assert_equal ['Community pilot', 1, 1, 1], row.values_at(:name, :communities, :offers, :engagements)
    assert_match(/\ACampaigns: 1 total\./, campaigns.text)

    communities = records('kind' => 'communities')
    assert_equal({ 'rules_current' => 1, 'rules_need_check' => 0 }, communities.data[:counts])
    assert_equal({ 'relevant' => 1 }, communities.data[:rows].first[:threads])

    Marketing::Offer.create!(community: @community, code: 'OLD5', terms: 'Old offer', destination_url: @campaign.storefront_url,
      starts_at: 20.days.ago, ends_at: 10.days.ago)
    offers = records('kind' => 'offers')
    assert_equal({ 'scheduled' => 0, 'active' => 1, 'ended' => 1 }, offers.data[:counts])
    active = records('kind' => 'offers', 'status' => 'active').data[:rows]
    assert_equal [['TEA10', 'community', 'active']], active.map { |offer| offer.values_at(:code, :for, :state) }
    assert_equal ['OLD5'], records('kind' => 'offers', 'query' => 'old').data[:rows].pluck(:code)
    ranged = records('kind' => 'offers', 'from' => 15.days.ago.to_date.iso8601, 'to' => 12.days.ago.to_date.iso8601)
    assert_equal ['OLD5'], ranged.data[:rows].pluck(:code)

    error = assert_raises(Mcp::ToolError) { records('kind' => 'offers', 'status' => 'shipped') }
    assert_match(/scheduled, active, ended/, error.message)
    assert_raises(Mcp::ToolError) { records('kind' => 'campaigns', 'status' => 'active') }
  end

  test 'discounts show the Shopify terms and say usage is not stored' do
    creator_discount
    outcome = records('kind' => 'discounts')
    row = outcome.data[:rows].first
    assert_equal ['CREATOR15', 'created', 'ACTIVE', true, '15% off', 100, true, 'not stored'],
      row.values_at(:code, :status, :shopify_status, :ready_to_share, :benefit, :usage_limit, :once_per_customer, :uses)
    assert_equal({ 'created' => 1 }, outcome.data[:counts])
    assert_match(/Usage counts are not stored/, outcome.text)
  end

  test 'reviews list community replies and their approval steps' do
    reply = draft_reply
    transition(reply, 'submit')
    outcome = records('kind' => 'reviews', 'status' => 'pending_review')
    row = outcome.data[:rows].first
    assert_equal ['pending_review', 'Herbal tea experiences', 'Tea group', 'TEA10', 'submit', 'Sam Marketer', 2],
      row.values_at(:status, :thread, :community, :offer_code, :last_review_action, :last_review_by, :review_steps)
    assert_equal({ 'pending_review' => 1 }, outcome.data[:counts])
  end

  test 'influencers and engagements never show private contact fields' do
    outcome = records('kind' => 'influencers')
    assert_equal({ 'interested' => 1, 'prospect' => 1 }, outcome.data[:counts])
    first = outcome.data[:rows].first
    assert_equal ['Tea Creator', 'Sam Marketer', true, 1], first.values_at(:name, :owner, :follow_up_due, :engagements)
    json = JSON.generate(outcome.data)
    ['creator@example.org', 'PRIVATE ADDRESS', 'PRIVATE CONTACT NOTES'].each { |secret| refute_includes json, secret }
    assert_equal ['Quiet Prospect'], records('kind' => 'influencers', 'status' => 'prospect').data[:rows].pluck(:name)

    engagements = records('kind' => 'engagements', 'query' => 'creator')
    assert_equal [['Tea sampler collaboration', 'Tea Creator', 'active']], engagements.data[:rows].map { |row| row.values_at(:title, :influencer, :status) }
  end

  test 'gifts total units and cost per currency without tracking or addresses' do
    gift(status: 'shipped', shipped_at: 2.days.ago)
    gift(status: 'proposed', items: [['Sleep Tincture', 'SLEEP-1', 1, nil]])
    outcome = records('kind' => 'gifts')
    assert_equal({ 'shipped' => 1, 'proposed' => 1 }, outcome.data[:counts])
    total = outcome.data[:totals].first
    assert_equal ['USD', 2, 3, 3000, 1700, 1], total.values_at(:currency, :gifts, :units, :product_cost_cents, :shipping_cost_cents, :gifts_missing_cost)
    shipped = records('kind' => 'gifts', 'status' => 'shipped', 'query' => 'calm')
    assert_equal [[2, 3000, '30.00']], shipped.data[:rows].map { |row| row.values_at(:units, :product_cost_cents, :product_cost_dollars) }
    json = JSON.generate(outcome.data)
    ['TRACK-SECRET-1', 'PRIVATE ADDRESS'].each { |secret| refute_includes json, secret }
    assert_match(/Gifts USD: 3 units, product cost 30.00, shipping 17.00 \(1 without unit cost\)/, outcome.text)
  end

  test 'events list who changed what, without payloads' do
    Marketing::CmsWriter.event!(@influencer, @actor, 'saved')
    outcome = records('kind' => 'events')
    row = outcome.data[:rows].first
    assert_equal ['saved', 'Sam Marketer', 'influencer', 'Tea Creator'], row.values_at(:action, :by, :subject, :subject_name)
    refute_includes JSON.generate(outcome.data), 'creator@example.org'
    assert_empty records('kind' => 'events', 'query' => 'gift').data[:rows]
  end

  test 'marketing_summary covers the period and what is waiting' do
    reply = draft_reply
    transition(reply, 'submit')
    gift(status: 'shipped', shipped_at: 1.hour.ago)
    creator_discount
    outcome = Mcp::Tools::MarketingSummary.new(token: @token).call('from' => 7.days.ago.to_date.iso8601)
    data = outcome.data
    assert_equal 1, data[:replies][:pending_review_now]
    assert_equal 2, data[:offers][:active_now]
    assert_equal [{ currency: 'USD', gifts: 1, units: 2, product_cost_cents: 3000, product_cost_dollars: '30.00',
                    shipping_cost_cents: 850, shipping_cost_dollars: '8.50', gifts_missing_cost: 0 }], data[:gifts][:shipped_in_period]
    assert_equal 1, data[:influencers][:follow_ups_due_now]
    assert_equal({ 'created' => 1 }, data[:discounts][:by_status])
    assert_match(/1 waiting for review; 2 offers live now/, outcome.text)
    assert_match(/Gifts shipped: 1 \(2 units, product 30.00 USD, shipping 8.50 USD\)/, outcome.text)
  end

  test 'both tools need marketing:read' do
    reporting = User.create!(email: 'mk-reporting@example.com', password: 'password123', role: 'reporting', name: 'Rep', tenant_id: Current.tenant.id)
    token = TeamChat::Token.new(reporting)
    refute Mcp::Tools::MarketingRecords.available_to?(token)
    refute Mcp::Tools::MarketingSummary.available_to?(token)
    assert Mcp::Tools::MarketingRecords.available_to?(@token)
  end
end
