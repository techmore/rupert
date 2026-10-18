# frozen_string_literal: true

require 'test_helper'
require_relative '../support/marketing_setup'

class MarketingEmailTest < ActiveSupport::TestCase
  include MarketingSetup
  include ActiveJob::TestHelper

  setup do
    setup_marketing
    @provider = mock('provider')
    ENV['APP_PUBLIC_URL'] = 'https://rupert.example'
    @domain = Marketing::EmailDomain.create!(tenant_id: @tenant.id, domain: 'mail.shop.test', kind: 'custom', status: 'verified', provider_id: '9')
    @sender = Marketing::EmailSender.create!(tenant_id: @tenant.id, email_domain: @domain, from_name: 'Shop', local_part: 'hello')
    @consented = customer('a@example.com', consent: true)
    @unconsented = customer('b@example.com', consent: false)
    @opted_out = customer('c@example.com', consent: true, unsubscribed: true)
    @suppressed = customer('d@example.com', consent: true)
    Marketing::EmailSuppression.add!('D@example.com', 'bounced')
    Marketing::EmailCampaignWorkflow.save_postal_address!('1 Main St, Town, ST 00000', actor: @actor)
    @campaign = Marketing::EmailCampaign.create!(tenant_id: @tenant.id, sender: @sender, name: 'Spring', subject: 'Hi', body: 'Sale!')
  end

  teardown do
    Current.reset
    ENV.delete('APP_PUBLIC_URL')
  end

  def customer(email, consent:, unsubscribed: false)
    Core::Customer.create!(tenant_id: @tenant.id, external_id: email, source: 'manual', email: email,
      marketing_consent_at: (Time.current if consent), marketing_unsubscribed_at: (Time.current if unsubscribed))
  end

  test 'audience includes only consented, not opted out, not suppressed customers' do
    assert_equal [@consented.id], Marketing::EmailAudience.customers(@campaign).pluck(:id)
  end

  test 'approval freezes recipients, needs confirmation and a mailing address' do
    assert_raises(Marketing::ReplyWorkflow::Invalid) do
      Marketing::EmailCampaignWorkflow.approve!(@campaign, actor: @actor, version: @campaign.lock_version, confirmed: '0')
    end
    Setting.where(key: Marketing::EmailCampaignWorkflow::POSTAL_KEY).delete_all
    assert_raises(Marketing::ReplyWorkflow::Invalid) do
      Marketing::EmailCampaignWorkflow.approve!(@campaign, actor: @actor, version: @campaign.lock_version, confirmed: '1')
    end
  end

  test 'unverified domain blocks sending' do
    @domain.update!(status: 'pending')
    assert_raises(Marketing::ReplyWorkflow::Invalid) do
      Marketing::EmailCampaignWorkflow.approve!(@campaign.reload, actor: @actor, version: @campaign.lock_version, confirmed: '1')
    end
  end

  test 'approve queues recipients and job sends with unsubscribe footer and honors a later opt-out' do
    assert_enqueued_with(job: EmailSendJob) do
      Marketing::EmailCampaignWorkflow.approve!(@campaign, actor: @actor, version: @campaign.lock_version, confirmed: '1')
    end
    assert_equal ['a@example.com'], @campaign.recipients.pluck(:email)
    @consented.update_columns(marketing_unsubscribed_at: Time.current)
    @provider.expects(:send_batch).never
    EmailSendJob.perform_now(@tenant.id, @campaign.id, provider: @provider)
    assert_equal 'skipped', @campaign.recipients.first.status
    assert_equal 'sent', @campaign.reload.status
  end

  test 'job sends consented recipients and records message ids' do
    Marketing::EmailCampaignWorkflow.approve!(@campaign, actor: @actor, version: @campaign.lock_version, confirmed: '1')
    @provider.expects(:send_batch).with do |messages|
      m = messages.first
      messages.size == 1 && m[:from] == 'Shop <hello@mail.shop.test>' && m[:text].include?('1 Main St') &&
        m[:text].include?('https://rupert.example/unsubscribe/') && m[:unsubscribe_url].start_with?('https://rupert.example/unsubscribe/')
    end.returns([Marketing::EmailProvider::Result.new(message_id: 'pm-1')])
    EmailSendJob.perform_now(@tenant.id, @campaign.id, provider: @provider)
    recipient = @campaign.recipients.first
    assert_equal ['sent', 'pm-1'], [recipient.status, recipient.provider_message_id]
    assert_equal 'sent', @campaign.reload.status
  end

  test 'sent campaigns cannot be edited' do
    Marketing::EmailCampaignWorkflow.approve!(@campaign, actor: @actor, version: @campaign.lock_version, confirmed: '1')
    assert_raises(ActiveRecord::RecordInvalid) { @campaign.reload.update!(body: 'Changed') }
  end

  test 'unsubscribe token opts the customer out inside its tenant and suppresses the address' do
    data = Marketing::EmailUnsubscribe.read(Marketing::EmailUnsubscribe.token(@consented))
    assert_equal @tenant.id, data['t']
    assert_nil Marketing::EmailUnsubscribe.read('garbage')
    Marketing::EmailUnsubscribe.apply!(data)
    assert @consented.reload.marketing_unsubscribed_at
    assert Marketing::EmailSuppression.blocked?('a@example.com')
  end

  test 'domain workflow stores provider dns records and verifies' do
    @provider.expects(:create_domain).with('news.shop.test').returns('ID' => 42, 'DKIMPendingHost' => 'pm._domainkey.news.shop.test',
      'DKIMPendingTextValue' => 'k=rsa;p=abc', 'ReturnPathDomain' => 'pm-bounces.news.shop.test', 'ReturnPathDomainCNAMEValue' => 'pm.mtasv.net')
    domain = Marketing::EmailDomainWorkflow.add_custom!('News.Shop.test', actor: @actor, provider: @provider)
    assert_equal 'pending', domain.status
    assert_equal 2, domain.dns_records.size
    @provider.expects(:verify_domain).with('42').returns('DKIMVerified' => true, 'ReturnPathDomainVerified' => true,
      'DKIMHost' => 'pm._domainkey.news.shop.test', 'DKIMTextValue' => 'k=rsa;p=abc',
      'ReturnPathDomain' => 'pm-bounces.news.shop.test', 'ReturnPathDomainCNAMEValue' => 'pm.mtasv.net')
    assert Marketing::EmailDomainWorkflow.check!(domain, actor: @actor, provider: @provider).verified?
  end

  test 'sender must belong to a domain of the same workspace' do
    other = Tenant.create!(name: 'Other', subdomain: 'other-email')
    foreign = Marketing::EmailDomain.create!(tenant_id: other.id, domain: 'other.test', kind: 'custom')
    sender = Marketing::EmailSender.new(tenant_id: @tenant.id, email_domain: foreign, from_name: 'X', local_part: 'x')
    refute sender.valid?
  end
end
