# frozen_string_literal: true

# Orchestrates sync runs against both platforms for a single tenant, mirroring
# everything into the database and recording each run in the SyncRun table.
# Guarded so only one sync runs per tenant at a time (DB-level, survives
# restarts).
class SyncEngine
  class AlreadyRunning < StandardError; end

  # Generous enough to cover backfills that legitimately run for a while; the
  # per-tenant unique index (not this window) is what stops overlapping syncs.
  STALE_RUN_AFTER = 3.hours

  class << self
    def run!(mode: "manual", actor: "user", tenant: nil, history_days: nil)
      Current.tenant = tenant if tenant
      raise ArgumentError, "No tenant in context" if Current.tenant_id.nil?

      run = create_run!(mode: mode, source: "all", actor: actor)
      Current.sync_run = run

      begin
        summary = {}
        square_frozen = PlatformPushGuard.frozen?("square")
        shopify = CatalogSyncer.sync!(since: backfill_since(history_days))
        summary[:shopify] = { products: shopify[:products], variants: shopify[:variants] }
        LedgerImporter.from_shopify_orders!(shopify.dig(:orders, "nodes"))

        # Square is frozen during its platform update: no traffic at all (reads
        # or writes) until it is explicitly unfrozen.
        if SquareClient.configured? && !square_frozen
          square = SquareSyncer.sync!(since: backfill_since(history_days))
          summary[:square] = { locations: square[:locations].length, orders: square[:orders].length }
          LedgerImporter.from_square_orders!(square[:orders])
        elsif SquareClient.configured?
          summary[:square] = { status: "skipped", reason: "Square is frozen by the push guard (platform update in progress)" }
        end

        AlertGenerator.sync!
        rows = Reconciler.build_rows
        Reconciler.record_run!(rows, mode: mode)
        summary[:reconcile] = Reconciler.summary(rows)

        if SquareClient.configured? && !square_frozen
          summary[:sizes] = SizeDeriver.process_all!
        end

        run.update!(status: "success", finishedAt: Time.current, details: summary.to_json)
        DataCache.bump!
        run
      rescue StandardError => e
        run.update!(status: "failed", error: e.message.to_s[0, 2000], finishedAt: Time.current)
        raise
      ensure
        Current.sync_run = nil
      end
    end

    def run_source!(source, actor: "user", tenant: nil)
      Current.tenant = tenant if tenant
      raise ArgumentError, "No tenant in context" if Current.tenant_id.nil?
      raise ArgumentError, "Unknown sync source" unless ["shopify", "square"].include?(source)

      run = create_run!(mode: "manual", source: source, actor: actor)
      Current.sync_run = run

      begin
        if source == "square"
          raise SquareClient::Error, "SQUARE_ACCESS_TOKEN is not set" unless SquareClient.configured?
          raise PlatformPushGuard::FrozenError, PlatformPushGuard.frozen_message("square") if PlatformPushGuard.frozen?("square")

          square = SquareSyncer.sync!
          LedgerImporter.from_square_orders!(square[:orders])
        else
          shopify = CatalogSyncer.sync!
          LedgerImporter.from_shopify_orders!(shopify.dig(:orders, "nodes"))
        end
        run.update!(status: "success", finishedAt: Time.current, details: { source: source }.to_json)
        DataCache.bump!
        run
      rescue StandardError => e
        run.update!(status: "failed", error: e.message.to_s[0, 2000], finishedAt: Time.current)
        raise
      ensure
        Current.sync_run = nil
      end
    end

    def running?
      SyncRun.unscoped.where(tenant_id: Current.tenant_id, status: "running").exists?
    end

    # One-way import of a SwipeSimple CSV export (SwipeSimple has no public
    # API). Idempotent, synchronous, and recorded as a sync run.
    def import_swipesimple_csv!(csv_text_or_path, actor: "user", tenant: nil)
      Current.tenant = tenant if tenant
      raise ArgumentError, "No tenant in context" if Current.tenant_id.nil?

      run = SyncRun.create!(mode: "csv", status: "running", source: "swipesimple", actor: actor, startedAt: Time.current)
      summary = SwipesimpleImporter.import!(csv_text_or_path)
      run.update!(status: "success", finishedAt: Time.current, details: summary.to_h.to_json)
      DataCache.bump!
      summary
    rescue StandardError => e
      run&.update!(status: "failed", error: e.message.to_s[0, 2000], finishedAt: Time.current)
      raise
    end

    private

    def backfill_since(history_days)
      return nil if history_days.nil?

      (Time.current - history_days.days).strftime("%Y-%m-%d")
    end

    # The running-run guard is enforced by a per-tenant partial unique index:
    # the insert itself is the lock. A race is caught as RecordNotUnique and
    # retried after stale runs are cleared, so two threads can never sync the
    # same tenant concurrently.
    def create_run!(mode:, source:, actor:)
      run = SyncRun.new(mode: mode, status: "running", source: source, actor: actor, startedAt: Time.current)
      run.save!
      run
    rescue ActiveRecord::RecordNotUnique
      recover_stale_runs!
      raise AlreadyRunning, "A sync is already running" if running?

      retry
    end

    def recover_stale_runs!
      cutoff = STALE_RUN_AFTER.ago
      SyncRun.unscoped.where(tenant_id: Current.tenant_id, status: "running").where('"startedAt" < ?', cutoff).update_all(
        status: "failed",
        finishedAt: Time.current,
        error: "Automatically recovered stale sync after #{STALE_RUN_AFTER.inspect}",
      )
    end
  end
end
