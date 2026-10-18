# frozen_string_literal: true

module Marketing
  class EmailDomainWorkflow
    def self.authorize!(actor)
      CmsWriter.authorize!(actor, 'marketing.review')
    end

    # Platform-owned subdomain: no DNS work, verified immediately.
    def self.add_shared!(actor:)
      authorize!(actor)
      base = ENV.fetch('MAIL_SHARED_DOMAIN', '').strip.downcase
      raise ReplyWorkflow::Invalid, 'A shared sending domain is not configured for this platform.' if base.blank?

      name = "#{Current.tenant.subdomain.to_s.downcase.gsub(/[^a-z0-9-]/, '-')}.#{base}"
      EmailDomain.create!(tenant_id: Current.tenant_id, domain: name, kind: 'shared', status: 'verified', verified_at: Time.current)
    end

    def self.add_custom!(name, actor:, provider: EmailProvider.build)
      user = authorize!(actor)
      record = EmailDomain.new(tenant_id: Current.tenant_id, domain: name, kind: 'custom')
      raise ActiveRecord::RecordInvalid, record unless record.valid?

      remote = provider.create_domain(record.domain)
      record.provider_id = remote['ID'].to_s
      record.dns_records_json = JSON.generate(records(remote))
      record.save!
      CmsWriter.event!(record, user, 'email_domain_added', { domain: record.domain })
      record
    end

    def self.check!(record, actor:, provider: EmailProvider.build)
      authorize!(actor)
      raise ActiveRecord::RecordNotFound unless record.tenant_id == Current.tenant_id && record.kind == 'custom'

      remote = provider.verify_domain(record.provider_id)
      ok = remote['DKIMVerified'] && remote['ReturnPathDomainVerified']
      record.update!(status: ok ? 'verified' : 'pending', checked_at: Time.current, dns_records_json: JSON.generate(records(remote)),
        verified_at: ok ? (record.verified_at || Time.current) : nil)
      record
    end

    def self.records(remote)
      [
        { 'type' => 'TXT', 'host' => remote['DKIMPendingHost'].presence || remote['DKIMHost'], 'value' => remote['DKIMPendingTextValue'].presence || remote['DKIMTextValue'], 'purpose' => 'DKIM', 'verified' => !!remote['DKIMVerified'] },
        { 'type' => 'CNAME', 'host' => remote['ReturnPathDomain'], 'value' => remote['ReturnPathDomainCNAMEValue'], 'purpose' => 'Return-path (bounces)', 'verified' => !!remote['ReturnPathDomainVerified'] }
      ].select { |r| r['host'].present? && r['value'].present? }
    end
  end
end
