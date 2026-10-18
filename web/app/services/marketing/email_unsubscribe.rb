# frozen_string_literal: true

module Marketing
  # Signed, tenant-bound unsubscribe links. Tokens do not expire: an old email
  # must always be able to opt out.
  module EmailUnsubscribe
    PURPOSE = 'marketing-email-unsubscribe'

    def self.token(customer)
      verifier.generate({ 't' => customer.tenant_id, 'c' => customer.id }, purpose: PURPOSE)
    end

    def self.read(token)
      data = verifier.verified(token.to_s, purpose: PURPOSE)
      data if data.is_a?(Hash) && data['t'].present? && data['c'].present?
    end

    def self.url(customer)
      "#{ENV.fetch('APP_PUBLIC_URL', 'http://localhost:3000').chomp('/')}/unsubscribe/#{token(customer)}"
    end

    # Applies the opt-out inside the token's tenant and returns the address.
    def self.apply!(data)
      tenant = Tenant.find_by(id: data['t'])
      return unless tenant

      Current.set(tenant: tenant) do
        customer = Core::Customer.find_by(id: data['c'])
        next unless customer

        customer.update_columns(marketing_unsubscribed_at: Time.current) if customer.marketing_unsubscribed_at.nil?
        EmailSuppression.add!(customer.email, 'unsubscribed') if customer.email.present?
        customer.email
      end
    end

    def self.verifier
      Rails.application.message_verifier(:marketing_email)
    end
  end
end
