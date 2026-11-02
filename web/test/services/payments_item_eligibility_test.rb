# frozen_string_literal: true

require 'test_helper'

class PaymentsItemEligibilityTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @owner = users(:regular_user)
    @catalog = ProcessorCatalog.create!(processor: 'authorize_net', enforced: true, approval_reference: 'ISO approval 2026-11-02', approved_by: @owner, approved_at: Time.current)
    @catalog.entries.create!(kind: 'sku', value: 'hh-cbd-tinc-3500')
    @catalog.entries.create!(kind: 'category', value: 'Pet  CBD')
    @catalog.entries.create!(kind: 'excluded_sku', value: 'HH-PET-FULL')
  end
  teardown { Current.reset }

  def check(processor = 'authorize_net', items) = Payments::ItemEligibility.check(processor: processor, items: items)

  test 'approved SKU and category pass; matching ignores case and spacing' do
    assert_predicate check([{ 'sku' => ' HH-CBD-TINC-3500 ', 'name' => 'CBD tincture' }]), :allowed?
    assert_predicate check([{ sku: 'HH-DOG-1', category: 'pet cbd', name: 'Dog chews' }]), :allowed?
  end

  test 'unlisted item is blocked with a cashier-ready message that names it' do
    result = check([{ 'sku' => 'HH-THCA-FLOWER', 'name' => 'THCA flower', 'category' => 'Flower' }, { 'sku' => 'HH-CBD-TINC-3500', 'name' => 'Tincture' }])
    assert_not result.allowed?
    assert_equal ['HH-THCA-FLOWER'], result.blocked.map { |row| row[:item].sku }
    assert_includes result.message, 'THCA flower (SKU HH-THCA-FLOWER): not on the Authorize.net approved list'
    assert_includes result.message, 'Card (Authorize.net)'
    assert_includes result.message, 'Use Cash instead'
    assert_equal ['cash'], result.alternatives
  end

  test 'excluded SKU wins over an approved category' do
    result = check([{ sku: 'hh-pet-full', category: 'Pet CBD', name: 'Full spectrum pet oil' }])
    assert_not result.allowed?
    assert_match(/excluded/, result.message)
  end

  test 'item with neither SKU nor category cannot be confirmed' do
    result = check([{ name: 'Custom amount', custom: true }])
    assert_not result.allowed?
    assert_match(/no SKU or category/, result.message)
  end

  test 'cash and processors without an enforced list keep current behaviour' do
    items = [{ sku: 'ANYTHING', name: 'Anything' }]
    assert_predicate check('cash', items), :allowed?
    assert_predicate check('nmi', items), :allowed?
    @catalog.update!(enforced: false)
    assert_predicate check(items), :allowed?
  end

  test 'routing suggests only cash or an enforced processor that approved the item, never an unrestricted one' do
    nmi = ProcessorCatalog.create!(processor: 'nmi', enforced: true, approval_reference: 'Backup ISO letter')
    nmi.entries.create!(kind: 'sku', value: 'HH-MUSH-1')
    result = check([{ sku: 'HH-MUSH-1', name: 'Mushroom gummies' }])
    assert_equal %w[cash nmi], result.alternatives
    assert_includes result.message, 'Use Cash or Card (NMI) instead'
    # card_terminal has no enforced list, so it is never offered as a route.
    assert_not_includes check([{ sku: 'HH-X' }]).alternatives, 'card_terminal'
  end

  test 'enforcing requires a recorded processor approval' do
    catalog = ProcessorCatalog.new(processor: 'card_terminal', enforced: true)
    assert_not catalog.valid?
    assert catalog.errors[:approval_reference].any?
  end

  test 'another workspace list never applies' do
    other = Tenant.create!(name: 'Other shop', subdomain: 'othershop-elig')
    Current.set(tenant: other) do
      assert_predicate check([{ sku: 'HH-THCA-FLOWER' }]), :allowed?
      assert_nil ProcessorCatalog.find_by(processor: 'authorize_net')
    end
  end

  test 'registered guardrail rules (F70) apply to every processor check' do
    rule = ->(processor:, item:) { 'needs a current COA' if item.sku == 'HH-CBD-TINC-3500' && processor != 'cash' }
    Payments::ItemEligibility.register_rule(rule)
    result = check([{ sku: 'HH-CBD-TINC-3500', name: 'Tincture' }])
    assert_not result.allowed?
    assert_match(/needs a current COA/, result.message)
    assert_raises(Payments::ItemEligibility::Blocked) { Payments::ItemEligibility.check!(processor: 'authorize_net', items: [{ sku: 'HH-CBD-TINC-3500' }]) }
  ensure
    Payments::ItemEligibility.rules.delete(rule)
  end

  test 'approved list doubles as the F70 processor allow-list (#name, #permits?)' do
    list = ProcessorCatalog.allow_list('authorize_net')
    assert_equal 'Authorize.net', list.name
    item = Struct.new(:sku, :category, :name, :variant_id)
    assert list.permits?(item.new('HH-CBD-TINC-3500', nil, 'Tincture', '1'))
    assert list.permits?(item.new(nil, 'pet cbd', 'Dog chews', '2'))
    assert_not list.permits?(item.new('HH-PET-FULL', 'Pet CBD', 'Full spectrum', '3'))
    assert_not list.permits?(item.new('HH-THCA-1', 'THCA Flower', 'Flower', '4'))
    assert_nil ProcessorCatalog.allow_list('nmi')
    f70_item = Struct.new(:sku, :category_name, :compliant_name, :source_variant_id)
    assert Payments::ItemEligibility.allow_list('authorize_net').permits?(f70_item.new(nil, 'Pet CBD', 'Dog chews', '9'))
    assert_not Payments::ItemEligibility.allow_list('authorize_net').permits?(f70_item.new('HH-THCA-1', 'THCA Flower', 'Flower', '10'))
    unrestricted = Payments::ItemEligibility.allow_list('nmi')
    assert_equal 'NMI', unrestricted.name
    assert unrestricted.permits?(f70_item.new('HH-THCA-1', 'THCA Flower', 'Flower', '10'))
    @catalog.update!(enforced: false)
    assert_nil ProcessorCatalog.allow_list('authorize_net')
    assert Payments::ItemEligibility.allow_list('authorize_net').permits?(f70_item.new('HH-THCA-1', nil, nil, nil))
  end

  test 'Blocked is a Pos::Error so POS controllers render it' do
    assert_operator Payments::ItemEligibility::Blocked, :<, Pos::Error
  end

  test 'unknown processor is a programming error' do
    assert_raises(ArgumentError) { check('square', []) }
  end

  test 'tender mapping' do
    assert_equal 'card_terminal', Payments::ItemEligibility.processor_for_tender('card_a920')
    assert_equal 'nmi', Payments::ItemEligibility.processor_for_tender('card', 'nmi')
    assert_equal 'authorize_net', Payments::ItemEligibility.processor_for_tender('card', nil)
    assert_equal 'cash', Payments::ItemEligibility.processor_for_tender('cash', 'nmi')
  end
end
