# frozen_string_literal: true

require 'test_helper'

class SitemapTest < ActionDispatch::IntegrationTest
  test 'lists the routed public pages for anyone, signed out' do
    get '/sitemap.xml'
    assert_response :success
    assert_equal 'application/xml', response.media_type
    assert_includes response.headers['Cache-Control'], 'public'
    locs = Nokogiri::XML(response.body).remove_namespaces!.xpath('//loc').map(&:text)
    assert_equal "#{request.base_url}/", locs.first
    assert_includes locs, "#{request.base_url}/privacy"
    assert_includes locs, "#{request.base_url}/support"
    assert_equal SitemapsController.routed_paths.size, locs.size
  end

  test 'leaves out pages this build does not route' do
    assert_includes SitemapsController.routed_paths, '/privacy'
    Rails.application.routes.stub(:recognize_path, ->(path, **) { path == '/privacy' ? {} : raise(ActionController::RoutingError, path) }) do
      assert_equal ['/privacy'], SitemapsController.routed_paths
    end
  end

  test 'a private single-store node has no sitemap' do
    WorkspaceNode.stub(:isolated?, true) do
      get '/sitemap.xml'
    end
    assert_response :not_found
  end
end
