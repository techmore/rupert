# frozen_string_literal: true

# Gatekeeper for outbound writes to Shopify and Square.
#
# Owner directive 2026-08-18: the push guard is REMOVED. No outbound write is
# blocked by an approval window or a maintenance freeze. Safety is instead a
# human/agent rule: ALWAYS ASK before any data-mutating push to Shopify or
# Square. This class is kept purely as read-only/operator information —
# freeze!/unfreeze!/approve!/status report state and history but nothing here
# blocks a write (authorize! is a no-op).
#
# State is stored per tenant as JSON blobs in Setting rows:
#   push_guard_shopify / push_guard_square
class PlatformPushGuard
  PLATFORMS = %w[shopify square].freeze

  DEFAULT_MIN_APPROVALS = 2
  DEFAULT_WINDOW_MINUTES = 60

  class LockedError < StandardError; end
  class FrozenError < LockedError; end

  class << self
    # No-op. Owner directive 2026-08-18: the push guard is removed — neither
    # approval windows nor the maintenance freeze block writes. The safeguard
    # is a human/agent rule to ALWAYS ASK before any data-mutating push.
    def authorize!(platform, actor: "system")
      platform = normalize(platform)
      require_tenant!
      true
    end

    def approve!(platform, email:)
      platform = normalize(platform)
      require_tenant!
      email = email.to_s.strip.downcase
      raise ArgumentError, "Approver email is required" if email.blank?

      blob = load(platform)
      fresh = fresh_approvals(blob)
      unless fresh.any? { |a| a["email"].to_s.casecmp?(email) }
        fresh << { "email" => email, "at" => Time.current.iso8601 }
        audit!(blob, "approve", platform, email, "approval recorded")
      end

      distinct = fresh.map { |a| a["email"] }.uniq
      if distinct.length >= min_approvals
        blob["window"] = {
          "opened_at" => Time.current.iso8601,
          "expires_at" => (Time.current + window_minutes.minutes).iso8601,
        }
        audit!(blob, "window_open", platform, email, "#{distinct.length}/#{min_approvals} approvals")
      else
        blob["window"] = nil
      end
      blob["approvals"] = fresh
      save(platform, blob)

      {
        platform: platform,
        approved_by: distinct.length,
        needed: min_approvals,
        window_open: blob["window"].present?,
        window_expires_at: blob["window"]&.dig("expires_at"),
      }
    end

    def revoke!(platform, email:)
      platform = normalize(platform)
      require_tenant!
      email = email.to_s.strip.downcase

      blob = load(platform)
      approvals = Array(blob["approvals"]).reject { |a| a["email"].to_s.casecmp?(email) }
      blob["approvals"] = approvals
      if blob["window"].present? && approvals.map { |a| a["email"] }.uniq.length < min_approvals
        blob["window"] = nil
      end
      audit!(blob, "revoke", platform, email, "approval revoked")
      save(platform, blob)
      status(platform)
    end

    # Hard block for maintenance/update windows. Overrides approvals.
    def freeze!(platform, reason: nil, actor: "user")
      platform = normalize(platform)
      require_tenant!

      blob = load(platform)
      blob["frozen"] = true
      blob["freeze_reason"] = reason.to_s.presence
      blob["frozen_by"] = actor.to_s
      blob["frozen_at"] = Time.current.iso8601
      audit!(blob, "freeze", platform, actor.to_s, reason.to_s.presence || "maintenance")
      save(platform, blob)
      status(platform)
    end

    def unfreeze!(platform, actor: "user")
      platform = normalize(platform)
      require_tenant!

      blob = load(platform)
      blob["frozen"] = false
      blob["freeze_reason"] = nil
      audit!(blob, "unfreeze", platform, actor.to_s, "maintenance window closed")
      save(platform, blob)
      status(platform)
    end

    def frozen?(platform)
      platform = normalize(platform)
      require_tenant!

      override = env_override("PUSH_FREEZE_#{platform.upcase}")
      return override == "1" if override.present?

      blob = load(platform)
      return true if blob["frozen"] == true
      return false if record_exists?(platform)

      # Default policy while no record exists yet: Square is frozen during its
      # platform update (until someone explicitly unfreezes it); Shopify is not.
      platform == "square"
    end

    def window_open?(platform)
      platform = normalize(platform)
      require_tenant!
      return false if frozen?(platform)

      blob = load(platform)
      expires = blob.dig("window", "expires_at")
      return false if expires.blank?

      if Time.current >= parse_time(expires)
        blob["window"] = nil
        save(platform, blob)
        return false
      end

      true
    end

    def status(platform)
      platform = normalize(platform)
      require_tenant!

      blob = load(platform)
      approvals = Array(blob["approvals"])
      window = blob["window"]
      {
        platform: platform,
        label: label(platform),
        frozen: frozen?(platform),
        freeze_reason: blob["freeze_reason"],
        default_policy: !record_exists?(platform),
        approvals: approvals.map { |a| { email: a["email"], at: a["at"] } },
        approvals_needed: approvals.map { |a| a["email"] }.uniq.length,
        approvals_required: min_approvals,
        window_open: window.present? && Time.current < parse_time(window["expires_at"]),
        window_opened_at: window&.dig("opened_at"),
        window_expires_at: window&.dig("expires_at"),
        history: Array(blob["history"]).last(20),
      }
    end

    def status_all
      PLATFORMS.map { |platform| status(platform) }
    end

    def min_approvals
      value = config("PUSH_GUARD_MIN_APPROVALS").to_i
      value.positive? ? value : DEFAULT_MIN_APPROVALS
    end

    def window_minutes
      value = config("PUSH_GUARD_WINDOW_MINUTES").to_i
      value.positive? ? value : DEFAULT_WINDOW_MINUTES
    end

    def label(platform)
      platform.to_s == "square" ? "Square" : "Shopify"
    end

    def frozen_message(platform)
      status = status(platform)
      reason = status[:freeze_reason].presence || "maintenance"
      "Pushes to #{label(platform)} are FROZEN (#{reason}). Unfreeze it before any write is allowed."
    end

    def locked_message(platform)
      status = status(platform)
      "Pushes to #{label(platform)} are locked: #{status[:approvals_needed]} of #{status[:approvals_required]} " \
        "approvals. A second person must approve (or run `bin/rails ops:push_guard:approve[#{platform},EMAIL]`) to open a push window."
    end

    private

    def load(platform)
      raw = Setting.find_by(key: key(platform), tenant_id: Current.tenant_id)&.value
      return {} if raw.blank?

      parsed = JSON.parse(raw)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def save(platform, blob)
      Setting.find_or_create_for(key(platform), Current.tenant_id) do |setting|
        setting.value = JSON.generate(blob)
      end
    end

    def record_exists?(platform)
      Setting.exists?(key: key(platform), tenant_id: Current.tenant_id)
    end

    def key(platform)
      "push_guard_#{platform}"
    end

    # Approvals that have not aged out of the window's lifetime.
    def fresh_approvals(blob)
      Array(blob["approvals"]).reject do |approval|
        (Time.current - parse_time(approval["at"])) > window_minutes.minutes
      end
    end

    def audit!(blob, action, platform, by, detail)
      history = Array(blob["history"])
      history << {
        "action" => action,
        "platform" => platform,
        "by" => by.to_s,
        "at" => Time.current.iso8601,
        "detail" => detail.to_s,
      }
      blob["history"] = history.last(50)
    end

    def env_override(key)
      setting = EnvStore.scoped(key)
      return setting.value if setting

      ENV[key].presence
    end

    def config(key)
      setting = EnvStore.scoped(key)
      return setting.value if setting

      ENV[key].presence
    end

    def parse_time(value)
      value.present? ? Time.zone.parse(value.to_s) : nil
    end

    def normalize(platform)
      normalized = platform.to_s.strip.downcase
      raise ArgumentError, "Unknown platform: #{platform.inspect} (expected #{PLATFORMS.join(" or ")})" unless PLATFORMS.include?(normalized)

      normalized
    end

    def require_tenant!
      raise ArgumentError, "No tenant in context" if Current.tenant_id.nil?
    end
  end
end
