# frozen_string_literal: true

# Shared helpers for the Shopify/Square sync services: the order-history
# window (SYNC_HISTORY_DAYS) and location upserts, which were previously
# duplicated verbatim between CatalogSyncer and SquareSyncer.
module SyncConcern
  extend ActiveSupport::Concern

  # How far back to look for orders. Configurable via SYNC_HISTORY_DAYS
  # (defaults to 30 days to match the original behavior).
  def history_lookback
    days = EnvStore.fetch('SYNC_HISTORY_DAYS', '').to_i
    days.positive? ? days.days : 30.days
  end

  # Finds or creates a mirrored Location row. Optional attributes are only
  # written when present so each source can carry what its API provides.
  def upsert_location(source:, external_id:, name:, kind: nil, active: true, timezone: nil)
    record = Location.find_or_initialize_by(source: source, externalId: external_id)
    record.name = name
    record.kind = kind if kind
    record.timezone = timezone if timezone
    record.active = active
    record.syncedAt = Time.current
    record.save!
    record
  end
end
