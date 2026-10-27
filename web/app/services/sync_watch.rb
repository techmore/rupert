# frozen_string_literal: true

# Read-only host monitoring: each configured catalog source in each active
# workspace needs its own acquisition watermark. A combined run may skip Square.
module SyncWatch
  OTHER_SOURCES = %w[ctrax square swipesimple authorize_net bank].freeze

  module_function

  def failures(max_age: 45.minutes, now: Time.current)
    failures = []
    Tenant.where(status: 'active').find_each do |tenant|
      Current.set(tenant: tenant) do
        sources = []
        sources << 'shopify' if EnvStore.fetch('SHOPIFY_CLIENT_ID', '').present?
        sources << 'square' if SquareClient.configured?
        sources.each do |source|
          watermark = CatalogSyncHistory.watermark(source)
          next if watermark && watermark <= now && watermark >= now - max_age

          failures << { tenant_id: tenant.id, source: source, last_success: watermark&.utc&.iso8601 }
        end

        # These integrations have different schedules and opt-in switches.
        # Reuse the same per-channel health rules shown in Connections rather
        # than treating a successful catalog sync as evidence for all of them.
        OTHER_SOURCES.each do |source|
          SourceHealth.for(key: source).each do |channel|
            next if source == 'square' && channel[:operation] == 'catalog'

            unavailable = %w[Saved\ credentials\ unreadable Diagnostics\ unavailable].include?(channel[:state])
            next unless channel[:enabled] || unavailable

            last = channel[:last_success_at] || channel[:legacy_at]
            missing = channel[:state] == 'Awaiting observed success' && last.nil?
            latest = Array(channel[:history]).find { |entry| entry[:status] != 'skipped' }
            failed = latest&.dig(:status) == 'failed'
            next unless unavailable || channel[:alert] || missing || failed

            failures << { tenant_id: tenant.id, source: "#{source}/#{channel[:operation]}",
              last_success: last&.utc&.iso8601, state: failed ? 'Failed' : channel[:state] }
          end
        end
      end
    rescue ActiveRecord::Encryption::Errors::Decryption
      failures << { tenant_id: tenant.id, source: 'configuration', last_success: nil }
    ensure
      RequestStore.clear!
    end
    failures
  end
end
