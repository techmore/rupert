# frozen_string_literal: true

module Marketing
  class EmailController < BaseController
    before_action :authorize_write, only: [:postal_address]

    def index
      @domains = EmailDomain.order(:domain).limit(100)
      @senders = EmailSender.includes(:email_domain).order(:local_part).limit(100)
      @campaigns = EmailCampaign.includes(:sender).order(id: :desc).limit(50)
      @postal_address = EmailCampaignWorkflow.postal_address
      @consented = EmailAudience.customers.count
      @shared_available = ENV['MAIL_SHARED_DOMAIN'].present?
    end

    def postal_address
      EmailCampaignWorkflow.save_postal_address!(params[:postal_address], actor: Current.user)
      redirect_to(marketing_email_path, notice: 'Mailing address saved.')
    end
  end
end
