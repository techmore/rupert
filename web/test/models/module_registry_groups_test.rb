# frozen_string_literal: true

require 'test_helper'

class ModuleRegistryGroupsTest < ActiveSupport::TestCase
  def areas = ModuleRegistry.singleton_class::AREAS

  test 'every grouped area lists each of its modules in exactly one group' do
    areas.select { |area| area[:groups] }.each do |area|
      grouped = area[:groups].flat_map { |group| group[:modules] }
      assert_equal grouped.uniq, grouped, "#{area[:key]} lists a module in more than one group"
      assert_empty area[:modules] - grouped, "#{area[:key]} has modules outside every group"
    end
  end

  test 'groups_for keeps only visible modules and drops empty groups' do
    area = areas.find { |a| a[:key] == 'money' }
    visible = ModuleRegistry.all.select { |entry| %w[bookkeeping reports].include?(entry.key) }
    groups = ModuleRegistry.groups_for(area, visible)
    assert_equal ['Everyday', 'Reports & planning'], groups.map { |group| group[:name] }
    assert_equal ['bookkeeping'], groups.first[:modules].map(&:key)
  end

  test 'group_for gives the shared group index and name, including in-page-only links' do
    assert_equal [0, 'Everyday'], ModuleRegistry.group_for('money', 'bookkeeping')
    assert_equal [3, 'Ledger & accounts'], ModuleRegistry.group_for('money', 'receipts')
    assert_nil ModuleRegistry.group_for('money', 'nonexistent')
    assert_nil ModuleRegistry.group_for('sell', 'sales')
  end
end

class OperationsWorkspaceGroupsTest < ActionView::TestCase
  include OperationsWorkspaceHelper

  test 'bookkeeping links are ordered and named by the registry groups' do
    links = [['Period locks', '/a', false, 'period_locks'], ['Overview', '/b', true, 'bookkeeping'],
             ['Accounts', '/c', false, 'finance_accounts'], ['Odd', '/d', false, nil]]
    grouped = group_money_links(:money, links)
    assert_equal ['Everyday', 'Books & review', 'Ledger & accounts', nil], grouped.map(&:last)
    assert_equal %w[Overview Period\ locks Accounts Odd], grouped.map(&:first)
  end

  test 'other workspaces stay one unlabelled group' do
    assert_equal [nil], group_money_links(:sales, [['Sales', '/s', false, nil]]).map(&:last)
  end
end
