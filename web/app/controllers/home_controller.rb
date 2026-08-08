# frozen_string_literal: true

class HomeController < ApplicationController
  include ShopifyApp::EmbeddedApp
  include ShopifyApp::EnsureInstalled
  include ShopifyApp::ShopAccessScopesVerification
  include ShopifyApp::EnsureHasSession

  def index
    render "home/index"
  end
end
