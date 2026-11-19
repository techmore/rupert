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

  # docs/compliance/dejavoo-tap-to-pay-compliance.md: the App Store privacy URL must say who
  # processes card payments and what Rupert keeps, and no page may sell a feature that has not shipped.
  test 'the privacy policy says who processes card payments and exactly what Rupert keeps' do
    get privacy_policy_path, headers: APP
    assert_response :success
    assert_select '#card-payments' do
      assert_select 'li', /Dejavoo and its iPOSpays service/
      assert_select 'li', /card brand, the last four digits, the approval code/
      assert_select 'li', /full card number, the first digits of the card/
      assert_select 'p', /takes no card payments.*planned and is not available yet/m
      assert_select "a[href^='mailto:']"
    end
    get employee_privacy_path
    assert_select "#card-payments a[href='#{privacy_policy_path(anchor: 'card-payments')}']"
  end

  test 'public pages use Apple names correctly, credit its trademarks and promise nothing early' do
    [privacy_policy_path, security_statement_path, public_integrations_path, support_path, terms_of_service_path, root_path].each do |path|
      get path
      assert_response :success, path
      text = Nokogiri::HTML(response.body).text
      assert_no_match(/Tap to Pay|official partner|(?:approved|certified) by (?:Apple|Dejavoo|Valmar)/i, text, "#{path}: not marketed before it ships")
      assert_no_match(/(?:Dejavoo|Apple|Valmar)[- ](?:certified|approved)|certified (?:Dejavoo|Apple) partner/i, text, path)
      assert_select '[data-trademark-credit]', /trademarks of Apple Inc\./ unless path == root_path
    end
    get support_path
    assert_select 'details', /will not work on iPad/
    get security_statement_path
    assert_select '#card-payments li', /will not work on iPad/
    assert_select '#card-payments', /Each merchant completes its own PCI DSS self-assessment/
  end

  test 'the marketing page links every policy page' do
    get root_path
    assert_response :success
    %w[terms refunds security integrations privacy support].each do |path|
      assert_select "footer a[href='https://pos.rupertpos.com/#{path}']", { minimum: 1 }, path
    end
  end
end
