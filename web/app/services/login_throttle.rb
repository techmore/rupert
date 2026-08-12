# frozen_string_literal: true

# Brute-force throttle for password login, backed by the access log. An IP or
# email with too many recent failures is locked out for a cooldown window. Only
# counts real authentication failures (rate-limited rows excluded so the
# lockout can't extend itself).
class LoginThrottle
  WINDOW = 15.minutes
  LOCKOUT = 15.minutes
  IP_FAILURES = 10
  EMAIL_FAILURES = 5

  class << self
    def blocked?(ip: nil, email: nil)
      return true if ip_blocked?(ip)
      return true if email.present? && email_blocked?(email)

      false
    end

    def lockout_minutes(ip: nil, email: nil)
      return unless blocked?(ip: ip, email: email)

      scope = AccessLog.where(source: "password", status: "failure")
        .where.not(detail: "rate limited")
        .where("created_at >= ?", WINDOW.ago)
      scope = scope.where(ip: ip) if ip.present?
      scope = scope.where("lower(email) = ?", email.to_s.downcase) if email.present?

      latest = scope.maximum(:created_at)
      return LOCKOUT / 60 if latest.nil?

      remaining = (latest + LOCKOUT) - Time.current
      [(remaining / 60.0).ceil, 1].max
    end

    private

    def ip_blocked?(ip)
      return false if ip.blank?

      failures(scope: AccessLog.where(ip: ip)) >= IP_FAILURES
    end

    def email_blocked?(email)
      return false if email.blank?

      failures(scope: AccessLog.where("lower(email) = ?", email.to_s.downcase)) >= EMAIL_FAILURES
    end

    def failures(scope:)
      scope.where(source: "password", status: "failure")
        .where.not(detail: "rate limited")
        .where("created_at >= ?", WINDOW.ago)
        .count
    end
  end
end
