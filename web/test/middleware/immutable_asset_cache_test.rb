# frozen_string_literal: true

require 'test_helper'

class ImmutableAssetCacheTest < ActiveSupport::TestCase
  def header_for(path, status: 200)
    app = ->(_env) { [status, { 'cache-control' => 'no-cache' }, ['ok']] }
    ImmutableAssetCache.new(app, prefix: '/api/assets').call('PATH_INFO' => path)[1]['cache-control']
  end

  test 'fingerprinted assets are cached for a year' do
    assert_equal ImmutableAssetCache::HEADER, header_for("/api/assets/tailwind-#{'a' * 64}.css")
  end

  test 'marketing files are cached for a day and revalidated in the background' do
    assert_equal ImmutableAssetCache::MARKETING_HEADER, header_for('/marketing/landing.css')
    assert_equal ImmutableAssetCache::MARKETING_HEADER, header_for('/marketing/shots/dashboard-light.webp')
    assert_equal 'no-cache', header_for('/marketing/missing.webp', status: 404)
    assert_equal 'no-cache', header_for('/marketingx/landing.css')
  end

  test 'pages, unfingerprinted files and errors keep their own header' do
    assert_equal 'no-cache', header_for('/api/assets/tailwind.css')
    assert_equal 'no-cache', header_for('/sales')
    assert_equal 'no-cache', header_for("/api/assets/app-#{'b' * 64}.js", status: 404)
  end
end
