# frozen_string_literal: true

# Port of applyPlan from the legacy console — applies reconciliation targets
# to Square and Shopify inventory with the shared-pool safety preflight.
class PlanApplier
  class SafetyLocked < StandardError; end

  class << self
    # Returns { applied:, results: [{ sku:, ok:, target:, actions: [] }] }
    def apply!(skus: nil, actor: "user")
      # Reconcile writes can be paused independently of syncing. While disabled,
      # applying is a safe no-op so neither the UI Apply button nor ops:apply
      # writes to either platform (sync keeps recording drift snapshots).
      unless FeatureFlag.enabled?(:reconcile)
        return { applied: 0, results: [], disabled: true }
      end

      rows = Reconciler.build_rows
      candidates = Reconciler.actionable_rows(rows, skus: skus)
      preflight!(rows, candidates)

      # Defense-in-depth: never half-apply a shared-SKU pool. A Square variation
      # linked to >1 Shopify variant is ambiguous; the Maintainer refuses these
      # and the Reconcile UI must too. Raise loudly rather than apply one row.
      shared = Reconciler.shared_skus
      if candidates.any? { |row| shared.include?(row.sku.to_s.downcase) }
        raise SafetyLocked, "Shared-SKU rows are not reconcilable (they map to >1 Shopify variant): #{candidates.select { |r| shared.include?(r.sku.to_s.downcase) }.map { |r| r.sku }.uniq.join(", ")}"
      end

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
            count_key = idempotency_key("hh-sync", row.sku, row.square_home_target)
            InventoryWriter.physical_count!(
              catalog_object_id: row.square_variation_id,
              quantity: row.square_home_target,
              location: square_home,
              reference_id: count_key,
              idempotency_key: count_key,
            )
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
              # Include the starting quantity + delta in the key so the same
              # delta against a different starting state isn't a duplicate.
              InventoryWriter.adjust_shopify!(
                inventory_item_id: row.inventory_item_id,
                delta: row.shopify_delta,
                location: shopify_location,
                reference: "reconciliation",
                idempotency_key: idempotency_key("hh", row.sku, "#{row.shopify_qty}->#{row.shopify_delta}"),
              )

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

    def preflight!(rows, candidates)
      reasons = []
      shopify_locations = Location.where(source: "shopify").count
      reasons << "Shopify must have exactly one active inventory location for this shared-pool setup" if shopify_locations != 1
      square_home = SquareSyncer.primary_location_id
      reasons << "Square home-base location is unavailable" if square_home.nil?
      # Only rows we will actually write can drive a home-base negative; shared,
      # multi-location, and derived SKUs are excluded from candidates and must
      # never lock the whole apply.
      blocked = candidates.count { |row| row.square_delta && !row.square_home_target.nil? && row.square_home_target.negative? }
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
      "#{prefix}-#{InventoryWriter.slugify(sku)}-#{target}"
    end
  end
end
