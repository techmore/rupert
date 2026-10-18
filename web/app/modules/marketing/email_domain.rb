# frozen_string_literal: true

module Marketing
  # A domain a workspace may send campaign email from. Custom domains are verified
  # by the provider after the workspace publishes DNS records; shared domains are
  # a platform-owned subdomain that needs no DNS work.
  class EmailDomain < Record
    self.table_name = 'marketing_email_domains'
    STATUSES = %w[pending verified failed].freeze
    KINDS = %w[custom shared].freeze
    DOMAIN_FORMAT = /\A(?=.{4,253}\z)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/

    has_many :senders, class_name: 'Marketing::EmailSender', foreign_key: :email_domain_id, dependent: :restrict_with_error
    before_validation { self.domain = domain.to_s.strip.downcase }
    validates :domain, format: { with: DOMAIN_FORMAT }, uniqueness: { scope: :tenant_id }
    validates :status, inclusion: { in: STATUSES }
    validates :kind, inclusion: { in: KINDS }

    def verified?
      status == 'verified'
    end

    def dns_records
      JSON.parse(dns_records_json.presence || '[]')
    end
  end
end
