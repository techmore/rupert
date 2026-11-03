# frozen_string_literal: true

require 'test_helper'

# The public pages payment partners and card-brand website rules expect: terms, cancellation and
# refunds, security and integrations. They are drafts until the owner signs off, so missing company
# facts show as visible placeholders rather than invented text.
class PublicPolicyPagesTest < ActionDispatch::IntegrationTest
  APP = { 'User-Agent' => 'Mozilla/5.0 (iPhone) Rupert iOS/1.0.0 (1); Hotwire Native iOS; Turbo Native iOS' }.freeze
  PAGES = {
    terms_of_service: 'Terms of service',
    refund_policy: 'Cancellation and refunds',
    security_statement: 'Security and data handling',
    public_integrations: 'Integrations'
  }.freeze
  COMPANY_KEYS = PublicPagesController::COMPANY_ENV.values

  teardown { COMPANY_KEYS.each { |key| ENV.delete(key) } }

  test 'policy pages are public, load Turbo and link to each other' do
    PAGES.each do |route, title|
      get public_send("#{route}_path"), headers: APP
      assert_response :success, route
      assert_select 'h1', title
      assert_select 'script[type=importmap]'
      assert_select 'nav[aria-label="Rupert policies"] a', 6
      %i[support privacy_policy terms_of_service refund_policy security_statement public_integrations].each do |link|
        assert_select "nav a[href='#{public_send("#{link}_path")}']"
      end
    end
  end

  test 'the app never sees prices or checkout links on these pages' do
    PAGES.each_key do |route|
      get public_send("#{route}_path"), headers: APP
      assert_no_match(/\$\d/, response.body, route)
      assert_select "a[href='#{billing_path}']", count: 0
    end
  end

  test 'drafts say so, and missing company facts are placeholders, never invented' do
    get terms_of_service_path
    assert_select '[data-draft-notice]', 1
    assert_select 'mark.owner-placeholder', minimum: 3
    get support_path
    assert_select '#company mark[data-owner-placeholder]', 4
    assert_includes response.body, 'CSP Cyber Security Pilot'
  end

  test 'company facts come from the deployment environment' do
    ENV['RUPERT_LEGAL_NAME'] = 'Example Pilot LLC'
    ENV['RUPERT_BUSINESS_ADDRESS'] = '1 Main St, Springfield'
    ENV['RUPERT_SUPPORT_PHONE'] = '+1 (555) 010-0000'
    ENV['RUPERT_SUPPORT_HOURS'] = 'Mon–Fri 9–5 Eastern'
    get support_path
    assert_select '#company mark', count: 0
    assert_select "#company a[href='tel:+15550100000']", '+1 (555) 010-0000'
    assert_includes response.body, '1 Main St, Springfield'
    ENV['RUPERT_SECURITY_EMAIL'] = 'security@example.test'
    get security_statement_path
    assert_select "a[href='mailto:security@example.test']"
  end

  test 'the security statement never claims a certification' do
    get security_statement_path
    assert_select '#card-payments'
    assert_no_match(/PCI(?: DSS)? (?:certified|compliant)|SOC 2 (?:certified|compliant)/i, response.body)
    assert_includes response.body, 'does not currently hold a PCI DSS attestation'
  end

  test 'the marketing page links every policy page' do
    get root_path
    assert_response :success
    %w[terms refunds security integrations privacy support].each do |path|
      assert_select "footer a[href='https://pos.rupertpos.com/#{path}']", { minimum: 1 }, path
    end
  end
end
