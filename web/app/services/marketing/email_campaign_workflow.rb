# frozen_string_literal: true

module Marketing
  class EmailCampaignWorkflow
    POSTAL_KEY = 'marketing_email_postal_address'
    DAILY_CAP = 500

    def self.authorize!(actor, review: false)
      actor = CmsWriter.authorize!(actor, 'marketing.write')
      raise Pundit::NotAuthorizedError unless !review || actor.can?('marketing.review')

      actor
    end

    def self.postal_address
      Setting.find_by(key: POSTAL_KEY, tenant_id: Current.tenant_id)&.value.to_s.strip
    end

    def self.save_postal_address!(value, actor:)
      CmsWriter.authorize!(actor, 'marketing.review')
      Setting.find_or_create_for(POSTAL_KEY, Current.tenant_id) { |s| s.value = value.to_s.strip[0, 500] }
    end

    def self.approve!(campaign, actor:, version:, confirmed:)
      actor = authorize!(actor, review: true)
      raise ReplyWorkflow::Invalid, 'Confirm the sender, audience and message before sending.' unless confirmed == '1'

      campaign.with_lock do
        raise ActiveRecord::StaleObjectError, campaign unless campaign.lock_version.to_s == version.to_s
        raise ActiveRecord::RecordNotFound unless campaign.tenant_id == Current.tenant_id
        raise ReplyWorkflow::Invalid, 'Only draft campaigns can be sent.' unless campaign.status == 'draft'
        raise ReplyWorkflow::Invalid, 'The sender’s domain is not verified yet.' unless campaign.sender.email_domain.verified?
        raise ReplyWorkflow::Invalid, 'Save your business mailing address before sending. Email law requires it in every message.' if postal_address.blank?

        customers = EmailAudience.customers(campaign).to_a
        raise ReplyWorkflow::Invalid, 'No customers with marketing consent match this audience.' if customers.empty?

        customers.each do |customer|
          campaign.recipients.create!(tenant_id: Current.tenant_id, customer: customer, email: customer.email.strip.downcase)
        end
        campaign.update!(status: 'approved', approved_by_id: actor.id, scheduled_at: Time.current)
        CmsWriter.event!(campaign, actor, 'email_campaign_approved', { recipients: customers.size })
      end
      EmailSendJob.perform_later(Current.tenant_id, campaign.id)
      campaign
    end

    def self.pause!(campaign, actor:)
      authorize!(actor, review: true)
      campaign.with_lock do
        raise ReplyWorkflow::Invalid, 'Only a campaign that is queued or sending can be paused.' unless %w[approved sending].include?(campaign.status)

        campaign.update!(status: 'paused')
      end
      campaign
    end

    def self.body_for(campaign, customer)
      <<~TEXT.strip
        #{campaign.body.strip}

        --
        #{postal_address}
        Unsubscribe: #{EmailUnsubscribe.url(customer)}
      TEXT
    end
  end
end
