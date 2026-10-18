# frozen_string_literal: true

module Marketing
  class EmailCampaignsController < BaseController
    before_action :authorize_write
    before_action :authorize_review, only: %i[approve pause]
    before_action :set_campaign, only: %i[show approve pause]

    def new
      @campaign = EmailCampaign.new
      @senders = verified_senders
    end

    def create
      attrs = params.require(:campaign).permit(:sender_id, :name, :subject, :body, :segment_status, :segment_source, :segment_tag)
      @campaign = EmailCampaign.create!(tenant_id: Current.tenant_id, sender: verified_senders.find(attrs[:sender_id]),
        **attrs.except(:sender_id).to_h.symbolize_keys)
      redirect_to(marketing_email_campaign_path(@campaign), notice: 'Draft saved. Review the audience before sending.')
    end

    def show
      @audience = EmailAudience.customers(@campaign).count if @campaign.status == 'draft'
      @counts = @campaign.recipients.group(:status).count
      @postal_address = EmailCampaignWorkflow.postal_address
    end

    def approve
      EmailCampaignWorkflow.approve!(@campaign, actor: Current.user, version: params[:lock_version], confirmed: params[:confirmed])
      redirect_to(marketing_email_campaign_path(@campaign), notice: 'Campaign approved. Sending has started.')
    end

    def pause
      EmailCampaignWorkflow.pause!(@campaign, actor: Current.user)
      redirect_to(marketing_email_campaign_path(@campaign), notice: 'Campaign paused. Unsent recipients stay queued.')
    end

    private

    def set_campaign
      @campaign = EmailCampaign.find(params[:id])
    end

    def verified_senders
      EmailSender.joins(:email_domain).where(marketing_email_domains: { status: 'verified' })
    end
  end
end
