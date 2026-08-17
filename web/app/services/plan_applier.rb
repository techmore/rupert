# frozen_string_literal: true

# Port of applyPlan from the legacy console — applies reconciliation targets
# to Square and Shopify inventory with the shared-pool safety preflight.
class PlanApplier
  class SafetyLocked < StandardError; end

  ADJUST_QUERY = <<~GRAPHQL
    mutation AdjustInventory($input: InventoryAdjustQuantitiesInput!, $idempotencyKey: String!) {
      inventoryAdjustQuantities(input: $input) @idempotent(key: $idempotencyKey) {
        inventoryAdjustmentGroup { createdAt changes { name delta } }
        userErrors { field message }
      }
    }
  GRAPHQL

  class << self
    # Returns { applied:, results: [{ sku:, ok:, target:, actions: [] }] }
    def apply!(skus: nil, actor: "user")
      rows = Reconciler.build_rows
      preflight!(rows)

      candidates = Reconciler.actionable_rows(rows, skus: skus)
      grouped = candidates.group_by { |row| row.sku.downcase }
      conflicts = grouped.select { |_, items| items.map { |i| "#{i.target}:#{i.square_variation_id}" }.uniq.length > 1 }
      if conflicts.any?
        raise SafetyLocked, "Conflicting duplicate Shopify SKUs must be fixed before applying: #{conflicts.keys.join(", ")}"
      end

      authorize_writes!(grouped.values.flatten, actor: actor)

      shopify_location = Location.shopify_primary
      square_home = SquareSyncer.primary_location_id

      applied = 0
      results = grouped.values.map(&:first).map do |row|
        notes = []
        ok = true

        if row.square_delta != 0 && square_home.present?
          begin
            SquareClient.request("/inventory/changes/batch-create", method: "POST", body: {
              idempotency_key: idempotency_key("hh-sync", row.sku, row.square_home_target),
              changes: [{
                type: "PHYSICAL_COUNT",
                physical_count: {
                  reference_id: idempotency_key("hh-sync", row.sku, row.square_home_target),
                  catalog_object_id: row.square_variation_id,
                  state: "IN_STOCK",
                  location_id: square_home.externalId,
                  quantity: row.square_home_target.to_s,
                  occurred_at: Time.current.iso8601,
                },
              }],
              ignore_unchanged_counts: true,
            })
            notes << "Square #{square_home.name}→#{row.square_home_target} (shared total #{row.target})"
            journal_movement(row, source: "reconcile", square_delta: row.square_delta, reference: "apply")
          rescue StandardError => e
            ok = false
            notes << "Square ✕ #{e.message}"
          end
        end

        if row.shopify_delta != 0
          if row.inventory_item_id.blank? || shopify_location.nil?
            ok = false
            notes << "Shopify write needs location + read/write inventory scopes (re-install app with access)"
          else
            begin
              result = ShopifyClient.graphql(ADJUST_QUERY, {
                input: {
                  reason: "correction",
                  name: "available",
                  referenceDocumentUri: "herbal-healers://inventory/reconciliation",
                  changes: [{ delta: row.shopify_delta, inventoryItemId: row.inventory_item_id, locationId: shopify_location.externalId }],
                },
                idempotencyKey: idempotency_key("hh", row.sku, row.shopify_delta),
              })
              user_errors = result.dig("inventoryAdjustQuantities", "userErrors") || []
              raise ShopifyClient::Error, user_errors.map { |item| item["message"] }.join("; ") if user_errors.any?

              notes << "Shopify #{row.shopify_delta.positive? ? "+" : ""}#{row.shopify_delta}"
              journal_movement(row, source: "reconcile", shopify_delta: row.shopify_delta, reference: "apply")
            rescue StandardError => e
              ok = false
              notes << "Shopify ✕ #{e.message}"
            end
          end
        end

        applied += 1 if ok
        { sku: row.sku, ok: ok, target: row.target, actions: notes }
      end

      record_apply(results)
      DataCache.bump!

      { applied: applied, results: results }
    end

    private

    # Multi-approval gate: no platform gets written unless a push window is
    # open for it. Authorized up-front so a blocked apply never partially runs.
    def authorize_writes!(rows, actor:)
      if rows.any? { |row| (row.shopify_delta || 0) != 0 }
        PlatformPushGuard.authorize!("shopify", actor: actor)
      end
      if rows.any? { |row| (row.square_delta || 0) != 0 }
        PlatformPushGuard.authorize!("square", actor: actor)
      end
    end

    # Update the most recent pending run's telemetry so the reports page shows
    # what was actually applied. Pure accounting on local rows — this never
    # triggers a run or an external write on its own.
    def record_apply(results)
      run = ReconcileRun.where(status: "pending").order(startedAt: :desc).first
      return unless run

      results.each do |result|
        run.items.where(sku: result[:sku]).update_all(
          ok: result[:ok],
          actions: Array(result[:actions]).join(", "),
        )
      end

      ok = run.items.where(ok: true).count
      failed = run.items.where(ok: false).count
      run.update!(
        applied: ok,
        failed: failed,
        status: run.items.where(ok: nil).none? ? "applied" : "pending",
      )
    end

    def preflight!(rows)
      reasons = []
      shopify_locations = Location.where(source: "shopify").count
      reasons << "Shopify must have exactly one active inventory location for this shared-pool setup" if shopify_locations != 1
      square_home = SquareSyncer.primary_location_id
      reasons << "Square home-base location is unavailable" if square_home.nil?
      blocked = rows.count { |row| row.square_delta && !row.square_home_target.nil? && row.square_home_target.negative? }
      reasons << "#{blocked} corrections would make the Square home-base count negative" if blocked.positive?

      raise SafetyLocked, "Inventory writes are safety-locked because the shared-pool preflight did not pass: #{reasons.join("; ")}" if reasons.any?
    end

    def journal_movement(row, source:, reference:, square_delta: 0, shopify_delta: 0)
      InventoryMovement.create!(
        sku: row.sku,
        shopifyVariantId: row.variant_id,
        squareVariationId: row.square_variation_id,
        source: source,
        direction: (square_delta + shopify_delta).negative? ? "out" : "in",
        delta: square_delta + shopify_delta,
        quantityBefore: row.shopify_qty || 0,
        quantityAfter: row.target || 0,
        reason: "Reconciliation applied",
        reference: reference,
        actor: "system",
        createdAt: Time.current,
      )
    end

    def idempotency_key(prefix, sku, target)
      slug = sku.gsub(/[^a-z0-9]/i, "").slice(0, 40)
      slug = "item" if slug.blank?
      "#{prefix}-#{slug}-#{target}"
    end
  end
end
