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
  VERSION_KEY = 'data_version'
  VERSION_TTL = 5.minutes
  DEFAULT_TTL = 15.minutes

  class << self
    # Fetch an aggregate, cached until the data version changes. Falls back to
    # computing the block directly if the cache store is unavailable.
    def fetch(name, ttl: DEFAULT_TTL, &block)
      key = cache_key(name)
      Rails.cache.fetch(key, expires_in: ttl, &block)
    rescue StandardError => e
      cache_store_error(e, "fetch(#{name})")
      block&.call
    end

    def delete(name)
      Rails.cache.delete(cache_key(name))
    rescue StandardError => e
      cache_store_error(e, "delete(#{name})")
    end

    # Bump the tenant's data version. Call this whenever mirrored data changes:
    # after a successful sync, inventory count approval, or POS settle.
    def bump!
      new_version = version + 1
      Setting.find_or_create_for(VERSION_KEY, Current.tenant_id) do |setting|
        setting.value = new_version.to_s
      end
      clear_version_cache
      new_version
    end

    # The current data version. Read from the version cache (short TTL) to avoid
    # a DB lookup on every request; falls back to the settings row. A cache-store
    # error must never 500 a request — fall back to the DB-backed value.
    def version
      Rails.cache.fetch(version_cache_key, expires_in: VERSION_TTL) do
        db_version
      end
    rescue StandardError => e
      cache_store_error(e, 'version')
      db_version
    end

    private

    # The authoritative version from the settings row (used as the cache-miss
    # value and as the fallback when the cache store errors).
    def db_version
      Setting.find_by(key: VERSION_KEY, tenant_id: Current.tenant_id)&.value.to_i || 0
    end

    # Clear the raw (unversioned) version-cache key so the next version read is
    # fresh. Swallows cache-store errors — the DB row is the source of truth.
    def clear_version_cache
      Rails.cache.delete(version_cache_key)
    rescue StandardError => e
      cache_store_error(e, 'clear_version_cache')
    end

    def cache_store_error(e, context)
      Rails.logger.warn("DataCache: cache store error in #{context} (#{e.class}: #{e.message}); fell back to database")
    end

    def cache_key(name)
      "dc/#{Current.tenant_id}/#{name}/v#{version}"
    end

    def version_cache_key
      "dc/#{Current.tenant_id}/data_version"
    end
  end
end
