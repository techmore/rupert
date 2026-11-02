# frozen_string_literal: true

require 'test_helper'
require_relative '../support/compliance_fixtures'

# F70 pre-sale check: one set of rules for the register, the event register and
# (F69) processor allow-lists.
class ComplianceItemEligibilityTest < ActiveSupport::TestCase
  include ComplianceFixtures

  setup do
    Current.tenant = tenants(:default_tenant)
    @location = compliance_store
    @tincture = approve!(@location, '11', name: 'Broad Spectrum Hemp Extract 1000mg', category: card_category, thc_mg_per_container: 0)
    @flower = approve!(@location, '22', name: 'Hemp Flower 3.5g', category: cash_category, card: false, thc_mg_per_container: 87.5)
  end
  teardown { Current.reset }

  test 'approved card item with a current COA passes for card and cash' do
    %w[card card_a920 card_terminal cash].each do |tender|
      result = check(%w[11], tender)
      assert result.allowed?, "#{tender}: #{result.issues.map(&:message)}"
    end
  end

  test 'items off the approved list, suspended or in a prohibited category never sell and cannot be overridden' do
    result = check(%w[33], 'cash')
    assert_equal [:not_approved], result.codes
    assert_not result.overridable?

    @tincture.update!(status: 'suspended')
    assert_equal [:suspended], check(%w[11], 'card').codes

    @tincture.update!(status: 'approved')
    banned = ComplianceCategory.create!(name: 'Vapes', prohibited: true)
    @tincture.update!(compliance_category: banned, card_eligible: false)
    result = check(%w[11], 'cash')
    assert_equal [:category_prohibited], result.codes
    assert_not result.overridable?
  end

  test 'card on a cash-only item is blocked but a manager may override; cash sells it' do
    result = check(%w[11 22], 'card')
    assert_not result.allowed?
    assert_equal [:card_ineligible], result.blocking.map(&:code)
    assert result.overridable?
    assert_equal '22', result.blocking.first.item_key
    assert check(%w[22], 'cash').allowed?
  end

  test 'item card flag and category card flag must both allow card' do
    @tincture.update!(compliance_category: cash_category)
    assert_equal [:card_ineligible], check(%w[11], 'card').blocking.map(&:code)
  end

  test 'unknown tenders fail safe to the card rules' do
    assert_equal :card, Compliance::ItemEligibility.tender_kind('ach_new_thing')
    assert_equal :cash, Compliance::ItemEligibility.tender_kind('cash')
    assert_not check(%w[22], 'ach_new_thing').allowed?
  end

  test 'a missing or lapsed COA blocks card (overridable) and only warns for cash' do
    @tincture.certificates_of_analysis.destroy_all
    card = check(%w[11], 'card')
    assert_equal [:coa_missing], card.blocking.map(&:code)
    assert card.overridable?
    cash = check(%w[11], 'cash')
    assert cash.allowed?
    assert_equal [:coa_missing], cash.warnings.map(&:code)

    add_coa!(@tincture.reload, tested_on: 400.days.ago.to_date)
    assert_equal [:coa_expired], check(%w[11], 'card').blocking.map(&:code)
    add_coa!(@tincture.reload, tested_on: 10.days.ago.to_date, expires_on: 2.days.ago.to_date)
    assert_equal [:coa_expired], check(%w[11], 'card').blocking.map(&:code)
    fresh = add_coa!(@tincture.reload, tested_on: 5.days.ago.to_date)
    assert check(%w[11], 'card').allowed?
    fresh.update!(status: 'withdrawn')
    assert_not check(%w[11], 'card').allowed?, 'a withdrawn certificate is never current'
  end

  test 'the policy sets how long a COA stays current' do
    @tincture.certificates_of_analysis.update_all(tested_on: 100.days.ago.to_date)
    policy = CompliancePolicy.new(coa_max_age_days: 90)
    assert_equal [:coa_expired], Compliance::ItemEligibility.check(lines(%w[11]), tender: 'card', policy: policy).blocking.map(&:code)
  end

  test 'federal THC per container limit warns before Dec 11, 2026 and blocks from that day without override' do
    before = check(%w[22], 'cash', on: Date.new(2026, 12, 10))
    assert before.allowed?
    assert_equal [:thc_over_federal_limit_soon], before.warnings.map(&:code)

    after = check(%w[22], 'cash', on: Date.new(2026, 12, 11))
    assert_equal [:thc_over_federal_limit], after.blocking.map(&:code)
    assert_not after.overridable?

    @tincture.update!(thc_mg_per_container: nil)
    assert_equal [:thc_unknown], check(%w[11], 'cash', on: Date.new(2026, 12, 11)).warnings.map(&:code)
  end

  test 'a processor allow-list (F69) refuses card for categories it does not accept' do
    allow_list = Compliance::ItemEligibility::CategoryAllowList.new(name: 'Valmar', category_names: ['Something else'])
    result = Compliance::ItemEligibility.check(lines(%w[11]), tender: 'card', processor: allow_list)
    assert_equal [:processor_not_allowed], result.blocking.map(&:code)
    assert_not result.overridable?
    assert Compliance::ItemEligibility.check(lines(%w[11]), tender: 'cash', processor: allow_list).allowed?, 'allow-lists only apply to card'
    ok = Compliance::ItemEligibility::CategoryAllowList.new(name: 'Valmar', category_names: [card_category.name.upcase])
    assert Compliance::ItemEligibility.check(lines(%w[11]), tender: 'card', processor: ok).allowed?
  end

  test 'catalog items expose sku and category for F69 processor allow-lists' do
    sku_list = Struct.new(:name, :skus) { def permits?(item) = skus.include?(item.sku) }
    @tincture.update!(sku: 'TINC-1000')
    assert_equal card_category.name, @tincture.category
    assert Compliance::ItemEligibility.check(lines(%w[11]), tender: 'card_terminal', processor: sku_list.new('Terminal', ['TINC-1000'])).allowed?
    assert_equal [:processor_not_allowed], Compliance::ItemEligibility.check(lines(%w[11]), tender: 'card_terminal', processor: sku_list.new('Terminal', [])).blocking.map(&:code)
  end

  test 'catalog items from another workspace are never found' do
    other = create_workspace('Other store', current: false)
    Current.set(tenant: other) do
      assert_equal [:not_approved], check(%w[11], 'cash').codes
    end
  end

  test 'compliant names reject health and marijuana claims' do
    item = ComplianceCatalogItem.new(location: @location, source_variant_id: '33', compliance_category: card_category, compliant_name: 'Pain Relief Balm')
    assert_not item.valid?
    assert_match(/health or marijuana claim/, item.errors[:compliant_name].first)
    item.compliant_name = 'Herbal Balm 2oz'
    item.receipt_name = 'Weed Balm'
    assert_not item.valid?
    item.receipt_name = 'Herbal Balm'
    assert item.valid?, item.errors.full_messages.to_sentence
  end

  test 'a prohibited category cannot carry card eligibility' do
    banned = ComplianceCategory.new(name: 'Drinks', prohibited: true, card_eligible: true)
    assert_not banned.valid?
  end

  private

  def lines(ids) = Compliance::ItemEligibility.lines_for_ctrax(location: @location, variant_ids: ids)
  def check(ids, tender, on: Date.new(2026, 11, 2)) = Compliance::ItemEligibility.check(lines(ids), tender: tender, on: on)
end
