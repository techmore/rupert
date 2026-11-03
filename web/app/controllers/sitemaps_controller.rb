# frozen_string_literal: true

# GET /sitemap.xml: the public pages search engines may list (https://www.sitemaps.org).
# A bare controller: no session, sign-in or workspace redirects apply. A private
# single-store node has no public site, so it answers 404.
class SitemapsController < ActionController::Base
  # Public pages, most important first. A path this build does not route is left out.
  PATHS = %w[/ /privacy /support /terms /refunds /security /integrations].freeze

  def show
    return head(:not_found) if WorkspaceNode.isolated?

    expires_in 1.day, public: true
    render xml: xml(self.class.routed_paths.map { |path| request.base_url + (path == '/' ? '/' : path) })
  end

  def self.routed_paths
    PATHS.select do |path|
      Rails.application.routes.recognize_path(path, method: :get)
      true
    rescue ActionController::RoutingError
      false
    end
  end

  private

  def xml(urls)
    entries = urls.map { |url| "  <url><loc>#{ERB::Util.html_escape(url)}</loc></url>" }
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
      #{entries.join("\n")}
      </urlset>
    XML
  end
end
