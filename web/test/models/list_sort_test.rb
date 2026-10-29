# frozen_string_literal: true

require 'test_helper'

class ListSortTest < ActiveSupport::TestCase
  COLUMNS = {
    'name' => ListSort.column('Name') { |dir| { last_name: dir, id: dir } },
    'created' => ListSort.column('Added', :date) { |dir| { created_at: dir, id: dir } },
    'status' => ListSort.column('Relationship', phrases: { 'asc' => 'lead first', 'desc' => 'inactive first' }) { |dir| { crm_status: dir } }
  }.freeze

  def build(sort, dir, aliases: {})
    ListSort.new(COLUMNS, sort: sort, dir: dir, default: %w[created desc], aliases: aliases)
  end

  test 'picks a whitelisted column and direction' do
    sort = build('name', 'desc')
    assert_equal %w[name desc], [sort.key, sort.dir]
    assert_equal 'descending', sort.aria_sort('name')
    assert_nil sort.aria_sort('created')
  end

  test 'unknown columns and directions fall back instead of reaching SQL' do
    assert_equal %w[created desc], build('name; DROP TABLE customers', 'asc').to_params.values
    assert_equal %w[created desc], build(nil, nil).to_params.values
    assert_equal %w[name asc], build('name', 'sideways').to_params.values
    assert_equal %w[name asc], build('name', "desc'--").to_params.values
  end

  test 'a heading toggles ascending then descending; other headings start ascending' do
    asc = build('name', 'asc')
    assert_equal 'desc', asc.next_dir('name')
    assert_equal 'asc', asc.next_dir('created')
    assert_equal 'asc', build('name', 'desc').next_dir('name')
  end

  test 'aliases apply only to links without a direction' do
    aliases = { 'recent' => %w[created desc], 'oldest' => %w[created asc] }
    assert_equal %w[created asc], build('oldest', nil, aliases: aliases).to_params.values
    assert_equal %w[created desc], build('oldest', 'asc', aliases: aliases).to_params.values
  end

  test 'words the sort for people' do
    assert_equal 'sorted by name, Z to A', build('name', 'desc').summary
    assert_equal 'Added, oldest first', build('created', 'desc').phrase('created', 'asc')
    assert_equal 'sorted by relationship, lead first', build('status', 'asc').summary
    assert_raises(ArgumentError) { ListSort.column('Odd', :colour) { {} } }
  end

  test 'applies the column order to a relation' do
    sql = build('name', 'desc').apply(Core::Customer.all).to_sql
    assert_match(/ORDER BY "customers"."last_name" DESC, "customers"."id" DESC/, sql)
  end
end
