# frozen_string_literal: true

# Orchestrates sync runs against both platforms, mirroring everything into
# the database and recording each run in the SyncRun table. Guarded so only
# one sync runs at a time (DB-level, survives restarts).
class SyncEngine
  class AlreadyRunning < StandardError; end

  class << self
    def run!(mode: "manual", actor: "user")
      guard_running!
      run = SyncRun.create!(mode: mode, status: "running", source: "all", actor: actor, startedAt: Time.current)

      begin
        summary = {}
        shopify = CatalogSyncer.sync!
        summary[:shopify] = { products: shopify[:products], variants: shopify[:variants] }
        LedgerImporter.from_shopify_orders!(shopify.dig(:orders, "nodes"))

        if SquareClient.configured?
          square = SquareSyncer.sync!
          summary[:square] = { locations: square[:locations].length, orders: square[:orders].length }
          LedgerImporter.from_square_orders!(square[:orders])
        end

        AlertGenerator.sync!
        rows = Reconciler.build_rows
        Reconciler.record_run!(rows, mode: mode)
        summary[:reconcile] = Reconciler.summary(rows)

        run.update!(status: "success", finishedAt: Time.current, details: summary.to_json)
        run
      rescue StandardError => e
        run.update!(status: "failed", error: e.message.to_s[0, 2000], finishedAt: Time.current)
        raise
      end
    end

    def run_source!(source, actor: "user")
      guard_running!
      raise ArgumentError, "Unknown sync source" unless %w[shopify square].include?(source)

      run = SyncRun.create!(mode: "manual", status: "running", source: source, actor: actor, startedAt: Time.current)

      begin
        if source == "square"
          raise SquareClient::Error, "SQUARE_ACCESS_TOKEN is not set" unless SquareClient.configured?

          square = SquareSyncer.sync!
          LedgerImporter.from_square_orders!(square[:orders])
        else
          shopify = CatalogSyncer.sync!
          LedgerImporter.from_shopify_orders!(shopify.dig(:orders, "nodes"))
        end
        run.update!(status: "success", finishedAt: Time.current, details: { source: source }.to_json)
        run
      rescue StandardError => e
        run.update!(status: "failed", error: e.message.to_s[0, 2000], finishedAt: Time.current)
        raise
      end
    end

    def running?
      SyncRun.where(status: "running").exists?
    end

    private

    def guard_running!
      raise AlreadyRunning, "A sync is already running" if running?
    end
  end
end
