# frozen_string_literal: true

# Version-keyed cache for expensive ERP aggregates (dashboard stats, reconcile
# rows, report queries). The data only changes when the sync engine runs or a
# manual mutation happens (inventory count approval, POS session settle), so we
# keep a per-tenant "data version" counter. Cache keys embed the version: when
# the version bumps, every cached aggregate is automatically stale and
# recomputed on the next read. Cheap aggregates stay versioned too, but the
# counter itself is read from Rails.cache with a short TTL to avoid a DB hit
# per request.
module DataCache
  VERSION_KEY = "data_version"
  VERSION_TTL = 5.minutes
  DEFAULT_TTL = 15.minutes

  class << self
    # Fetch an aggregate, cached until the data version changes.
    def fetch(name, ttl: DEFAULT_TTL, &block)
      Rails.cache.fetch(cache_key(name), expires_in: ttl, &block)
    end

    def delete(name)
      Rails.cache.delete(cache_key(name))
    end

    # Bump the tenant's data version. Call this whenever mirrored data changes:
    # after a successful sync, inventory count approval, or POS settle.
    def bump!
      new_version = version + 1
      Setting.find_or_initialize_by(key: VERSION_KEY, tenant_id: Current.tenant_id).tap do |setting|
        setting.value = new_version.to_s
        setting.save!
      end
      Rails.cache.delete(version_cache_key)
      new_version
    end

    # The current data version. Read from the version cache (short TTL) to avoid
    # a DB lookup on every request; falls back to the settings row.
    def version
      Rails.cache.fetch(version_cache_key, expires_in: VERSION_TTL) do
        Setting.find_by(key: VERSION_KEY, tenant_id: Current.tenant_id)&.value.to_i || 0
      end
    end

    private

    def cache_key(name)
      "dc/#{Current.tenant_id}/#{name}/v#{version}"
    end

    def version_cache_key
      "dc/#{Current.tenant_id}/data_version"
    end
  end
end
