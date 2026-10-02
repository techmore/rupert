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
end
