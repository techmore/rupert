# frozen_string_literal: true

require 'test_helper'

class WebMcpPublicSiteTest < ActiveSupport::TestCase
  EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/

  def all_text
    [WebMcp::PublicSite.llms_txt, WebMcp::PublicSite.llms_full_txt, WebMcp::PublicSite.manifest.to_json].join("\n")
  end

  test 'the only contact address anywhere is the owner address' do
    assert_equal ['sdolbec@rupertpos.com'], all_text.scan(EMAIL).uniq
  end

  test 'llms.txt follows the llmstxt.org shape' do
    text = WebMcp::PublicSite.llms_txt
    assert text.start_with?("# Rupert\n\n> ")
    assert_match %r{^- \[Create a free account\]\(https://rupertpos\.com/start\)}, text
    assert_match %r{^## Optional$}, text
    assert_includes WebMcp::PublicSite.llms_full_txt, text.strip
  end

  test 'public tools are read-only static answers with no arguments' do
    manifest = WebMcp::PublicSite.manifest
    assert_equal 'public', manifest[:mode]
    assert_equal %w[get_business_info get_pricing get_contact request_demo_link], manifest[:tools].pluck(:name)
    manifest[:tools].each do |tool|
      assert tool[:annotations][:readOnlyHint]
      assert_equal({}, tool[:inputSchema][:properties])
      assert tool[:result].present?
    end
  end

  test 'the demo link is a mailto the person sends themselves' do
    assert_equal 'mailto:sdolbec@rupertpos.com?subject=Rupert%20demo%20request', WebMcp::PublicSite::DEMO[:request_by_email]
  end

  test 'prices match the landing page' do
    landing = Rails.root.join('app/views/landing/index.html.erb').read
    ['$499', '$249.50', '$2,994', '$0'].each { |price| assert_includes landing, price }
    assert_includes WebMcp::PublicSite::PRICING.to_json, '$249.50 per month for 12 months'
    WebMcp::PublicSite::BUSINESS[:connections].each { |name| assert_includes landing, "<li>#{name}</li>" }
  end
end
