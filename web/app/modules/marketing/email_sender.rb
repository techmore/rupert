# frozen_string_literal: true

module Marketing
  class EmailSender < Record
    self.table_name = 'marketing_email_senders'
    belongs_to :email_domain, class_name: 'Marketing::EmailDomain'
    has_many :campaigns, class_name: 'Marketing::EmailCampaign', foreign_key: :sender_id, dependent: :restrict_with_error
    before_validation { self.local_part = local_part.to_s.strip.downcase }
    validates :from_name, presence: true, length: { maximum: 120 }
    validates :local_part, format: { with: /\A[a-z0-9][a-z0-9._-]{0,63}\z/ }, uniqueness: { scope: %i[tenant_id email_domain_id] }
    validates :reply_to, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
    validate { same_tenant(:email_domain) }

    def address
      "#{local_part}@#{email_domain.domain}"
    end

    def from_header
      "#{from_name.gsub(/["\r\n<>]/, '')} <#{address}>"
    end
  end
end
