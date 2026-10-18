# frozen_string_literal: true

# Sends an approved campaign in batches. Re-checks consent and suppression for
# every batch so an opt-out after approval is honored. Idempotent: only queued
# recipients are sent, and a message id is stored the moment the provider accepts.
class EmailSendJob < ApplicationJob
  BATCH = 100

  def perform(tenant_id, campaign_id, provider: Marketing::EmailProvider.build)
    Current.set(tenant: Tenant.find(tenant_id)) do
      campaign = Marketing::EmailCampaign.find(campaign_id)
      return unless %w[approved sending].include?(campaign.status)

      campaign.update!(status: 'sending')
      loop do
        campaign.reload
        break if campaign.status != 'sending'

        room = Marketing::EmailCampaignWorkflow::DAILY_CAP - Marketing::EmailRecipient.where(sent_at: Time.current.beginning_of_day..).count
        if room <= 0
          campaign.update!(status: 'paused', last_error: 'Daily send limit reached. Resume tomorrow.')
          break
        end

        batch = campaign.recipients.where(status: 'queued').includes(:customer).limit([BATCH, room].min).to_a
        break finish(campaign) if batch.empty?

        send_batch(campaign, batch, provider)
      end
    end
  rescue Marketing::EmailProvider::Error => e
    Current.set(tenant: Tenant.find(tenant_id)) { Marketing::EmailCampaign.find(campaign_id).update!(status: 'failed', last_error: e.message) }
  end

  private

  def send_batch(campaign, batch, provider)
    live = batch.select do |r|
      ok = r.customer.marketing_consent_at && r.customer.marketing_unsubscribed_at.nil? && !Marketing::EmailSuppression.blocked?(r.email)
      r.update!(status: 'skipped') unless ok
      ok
    end
    return if live.empty?

    messages = live.map do |r|
      { from: campaign.sender.from_header, to: r.email, subject: campaign.subject, reply_to: campaign.sender.reply_to.presence,
        text: Marketing::EmailCampaignWorkflow.body_for(campaign, r.customer),
        unsubscribe_url: Marketing::EmailUnsubscribe.url(r.customer),
        metadata: { tenant_id: campaign.tenant_id, campaign_id: campaign.id.to_s } }
    end
    provider.send_batch(messages).zip(live).each do |result, r|
      if result.message_id
        r.update!(status: 'sent', provider_message_id: result.message_id, sent_at: Time.current)
      else
        r.update!(status: 'failed', last_error: result.error)
      end
    end
  end

  def finish(campaign)
    campaign.update!(status: 'sent', sent_at: Time.current)
  end
end
