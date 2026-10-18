# frozen_string_literal: true

module Marketing
  # Addresses that must never receive campaign email from this workspace again.
  class EmailSuppression < Record
    self.table_name = 'marketing_email_suppressions'
    REASONS = %w[unsubscribed bounced complained manual].freeze
    before_validation { self.email = email.to_s.strip.downcase }
    validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, uniqueness: { scope: :tenant_id }
    validates :reason, inclusion: { in: REASONS }

    def self.add!(email, reason)
      create_with(reason: reason).find_or_create_by!(tenant_id: Current.tenant_id, email: email.to_s.strip.downcase)
    rescue ActiveRecord::RecordNotUnique
      find_by!(tenant_id: Current.tenant_id, email: email.to_s.strip.downcase)
    end

    def self.blocked?(email)
      exists?(email: email.to_s.strip.downcase)
    end
  end
end
