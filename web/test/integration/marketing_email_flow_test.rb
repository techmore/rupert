# frozen_string_literal: true

require 'test_helper'
require_relative '../support/marketing_setup'

class MarketingEmailFlowTest < ActionDispatch::IntegrationTest
  include MarketingSetup
  setup do
    setup_marketing
    post login_path, params: { email: 'admin@example.com', password: 'password' }
    @domain = Marketing::EmailDomain.create!(tenant_id: @tenant.id, domain: 'mail.shop.test', kind: 'custom', status: 'verified', provider_id: '9')
    @sender = Marketing::EmailSender.create!(tenant_id: @tenant.id, email_domain: @domain, from_name: 'Shop', local_part: 'hello')
    @campaign = Marketing::EmailCampaign.create!(tenant_id: @tenant.id, sender: @sender, name: 'Spring', subject: 'Hi', body: 'Sale!')
  end
  teardown { Current.reset }

  test 'pages render' do
    get marketing_email_path
    assert_select 'h1', 'Email campaigns'
    [marketing_email_path, new_marketing_email_campaign_path, marketing_email_campaign_path(@campaign)].each do |path|
      get path
      assert_response :success, path
    end
  end

  test 'saving a mailing address works and drafts are created' do
    patch marketing_email_postal_address_path, params: { postal_address: '1 Main St' }
    assert_redirected_to marketing_email_path
    assert_equal '1 Main St', Marketing::EmailCampaignWorkflow.postal_address
    post marketing_email_campaigns_path, params: { campaign: { sender_id: @sender.id, name: 'N', subject: 'S', body: 'B' } }
    assert_response :redirect
  end

  test 'public unsubscribe works without login and rejects bad tokens' do
    customer = Core::Customer.create!(tenant_id: @tenant.id, external_id: 'u1', source: 'manual', email: 'u@example.com', marketing_consent_at: Time.current)
    delete logout_path rescue nil
    token = Marketing::EmailUnsubscribe.token(customer)
    get email_unsubscribe_path(token)
    assert_response :success
    post email_unsubscribe_path(token)
    assert_response :success
    assert customer.reload.marketing_unsubscribed_at
    get email_unsubscribe_path('bad')
    assert_response :not_found
  end

  test 'webhook needs the shared secret and suppresses hard bounces' do
    ENV['POSTMARK_WEBHOOK_SECRET'] = 'shh'
    customer = Core::Customer.create!(tenant_id: @tenant.id, external_id: 'w1', source: 'manual', email: 'w@example.com', marketing_consent_at: Time.current)
    recipient = Marketing::EmailRecipient.create!(tenant_id: @tenant.id, campaign: @campaign, customer: customer, email: 'w@example.com', status: 'sent', provider_message_id: 'm-1')
    body = { RecordType: 'Bounce', Type: 'HardBounce', MessageID: 'm-1' }.to_json
    post '/webhooks/postmark', params: body, headers: { 'CONTENT_TYPE' => 'application/json' }
    assert_response :unauthorized
    auth = ActionController::HttpAuthentication::Basic.encode_credentials('postmark', 'shh')
    post '/webhooks/postmark', params: body, headers: { 'CONTENT_TYPE' => 'application/json', 'HTTP_AUTHORIZATION' => auth }
    assert_response :ok
    assert_equal 'bounced', recipient.reload.status
    Current.set(tenant: @tenant) { assert Marketing::EmailSuppression.blocked?('w@example.com') }
  ensure
    ENV.delete('POSTMARK_WEBHOOK_SECRET')
  end
end
