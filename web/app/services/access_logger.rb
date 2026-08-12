# frozen_string_literal: true

# Records authentication attempts for the access log. Never raises, so a
# logging hiccup can't break login.
class AccessLogger
  class << self
    def record(source:, status:, request:, email: nil, user: nil, detail: nil, domain: nil)
      AccessLog.create!(
        tenant_id: Current.tenant_id || user&.tenant_id,
        user_id: user&.id,
        email: email.presence || user&.email,
        domain: domain,
        source: source,
        status: status,
        ip: request.remote_ip,
        user_agent: request.user_agent&.to_s&.slice(0, 255),
        detail: detail,
      )
    rescue StandardError
      nil
    end
  end
end
