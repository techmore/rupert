# frozen_string_literal: true

require 'test_helper'
require_relative '../support/influencer_cms_setup'

# Through the whole middleware stack: only the landing page's static files become
# publicly cacheable. Anything the app itself answers under /marketing stays private,
# even when its address ends like an image or stylesheet.
class MarketingFileCacheTest < ActionDispatch::IntegrationTest
  include InfluencerCmsSetup

  teardown { Current.reset }

  test 'the landing page stylesheet and screenshots are cached publicly' do
    %w[/marketing/landing.css /marketing/shots/dashboard-light.webp].each do |path|
      get path
      assert_response :success, path
      assert_equal ImmutableAssetCache::MARKETING_HEADER, response.headers['Cache-Control'], path
    end
  end

  test 'a signed-in Marketing page is never cached publicly, whatever its address ends with' do
    setup_influencer_cms
    post login_path, params: { email: 'admin@example.com', password: 'password' }

    get marketing_influencers_path
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']

    # The app does not answer these as pages (406), and they must not turn into cacheable files.
    %w[.png .css .svg].each do |ending|
      get "#{marketing_influencers_path}#{ending}"
      assert_not_equal 200, response.status, ending
      assert_not_includes response.headers['Cache-Control'].to_s, 'public', ending
    end
  end

  test 'an answer from the app is private even when it sets no header and looks like a file' do
    with_routing do |set|
      set.draw { get '/marketing/report.png', to: ->(_env) { [200, { 'content-type' => 'image/png' }, ['made for one person']] } }
      get '/marketing/report.png'
      assert_equal 200, response.status
      assert_includes response.headers['Cache-Control'], 'private'
      assert_not_includes response.headers['Cache-Control'], 'public'
    end
  end

  test 'a signed-out request under /marketing is never cached publicly' do
    ['/marketing', '/marketing/influencers', '/marketing/influencers.png', '/marketing/nothing-here.css'].each do |path|
      get path
      assert_not_includes response.headers['Cache-Control'].to_s, 'public', path
    end
  end
end
