# frozen_string_literal: true

require 'test_helper'

class SearchServiceCacheTest < ActiveSupport::TestCase
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Current.reset
  end

  teardown do
    Current.reset
    Rails.cache = @original_cache
  end

  test 'repeated global searches use the tenant and permission-aware cache' do
    SearchService.expects(:search_orders).once.returns([])
    SearchService.expects(:search_customers).once.returns([])
    SearchService.expects(:search_variants).once.returns([])
    SearchService.expects(:search_employees).never

    assert_equal [], SearchService.search('Acme')
    assert_equal [], SearchService.search('acme')
  end

  test 'global search cache is isolated by tenant' do
    SearchService.expects(:search_orders).twice.returns([])
    SearchService.expects(:search_customers).twice.returns([])
    SearchService.expects(:search_variants).twice.returns([])
    SearchService.expects(:search_employees).never

    Current.tenant = Struct.new(:id).new('tenant-a')
    assert_equal [], SearchService.search('Acme')

    Current.tenant = Struct.new(:id).new('tenant-b')
    assert_equal [], SearchService.search('Acme')
  end
end
