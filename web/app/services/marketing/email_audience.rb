# frozen_string_literal: true

module Marketing
  # Customers who explicitly consented, have not opted out and are not suppressed.
  class EmailAudience
    def self.customers(campaign = nil, status: nil, source: nil, tag: nil)
      status, source, tag = campaign.segment_status, campaign.segment_source, campaign.segment_tag if campaign
      scope = Core::Customer.where.not(email: [nil, '']).where.not(marketing_consent_at: nil).where(marketing_unsubscribed_at: nil)
      scope = scope.where(crm_status: status) if status.present?
      scope = scope.where(source: source) if source.present?
      scope = scope.where('LOWER(tags) LIKE ?', "%#{Core::Customer.sanitize_sql_like(tag.to_s.downcase)}%") if tag.present?
      suppressed = EmailSuppression.where(tenant_id: Current.tenant_id).select(:email)
      scope.where.not('LOWER(customers.email) IN (?)', suppressed)
    end
  end
end
