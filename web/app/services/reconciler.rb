# frozen_string_literal: true

# Port of reconcilePlan + seedReconcilePlan from the legacy console — builds
# the SKU-level reconciliation plan from the mirrored database and records
# each plan as a ReconcileRun.
class Reconciler
  PRIORITIES = ["lowest", "shopify", "square"].freeze

  Row = Struct.new(
    :sku,
    :product,
    :variant,
    :variant_id,
    :inventory_item_id,
    :tracked,
    :priority,
    :shopify_qty,
    :square_qty,
    :square_home_qty,
    :target,
    :drift,
    :shopify_delta,
    :square_delta,
    :square_home_target,
    :square_variation_id,
    :derived,
    :image_url,
    keyword_init: true,
  )

  class << self
    def build_rows
      policies = InventoryPolicy.all.to_h { |p| [p.sku.downcase, p.priority] }
      home_location_id = SquareSyncer.primary_location_id
      links = SkuLink.linked.index_by(&:shopifyVariantId)
      size_skus = SizeFamilyMember.pluck(:sku).map { |s| s.to_s.downcase }.to_set

      square_totals = InventoryLevel.square_totals
      home_totals = if home_location_id
        InventoryLevel.mirrored("square").where(locationId: home_location_id).group(:squareVariationId).sum(:quantity)
      else
        {}
      end

      rows = []
      # Only sellable (ACTIVE) Shopify products participate in reconciliation.
      # Archived/DRAFT/UNLISTED products were dropped from the live catalog and
      # must not generate drift/actions.
      ShopifyVariant.joins(:product).where('"ShopifyProduct"."status" = ?', "ACTIVE")
        .where.not(sku: [nil, ""]).where(tracked: true).find_each do |variant|
        sku = variant.sku.to_s.strip
        next if sku.empty?

        link = links[variant.id]
        square_variation_id = link&.squareVariationId

        shopify_qty = variant.inventoryQuantity
        square_qty = nil
        square_home_qty = nil
        if square_variation_id.present?
          square_qty = square_totals.fetch(square_variation_id, 0)
          square_home_qty = home_totals.fetch(square_variation_id, 0)
        end

        priority = policies[sku.downcase] || "lowest"
        target = compute_target(priority, shopify_qty, square_qty)

        rows << Row.new(
          sku: sku,
          product: variant.product&.title || "",
          variant: variant.title,
          variant_id: variant.id,
          inventory_item_id: variant.inventoryItemId,
          tracked: variant.tracked,
          priority: priority,
          shopify_qty: shopify_qty,
          square_qty: square_qty,
          square_home_qty: square_home_qty,
          target: target,
          drift: !shopify_qty.nil? && !square_qty.nil? ? square_qty - shopify_qty : nil,
          shopify_delta: !target.nil? && !shopify_qty.nil? ? target - shopify_qty : nil,
          square_delta: !target.nil? && !square_qty.nil? ? target - square_qty : nil,
          square_home_target: !target.nil? && !square_qty.nil? && !square_home_qty.nil? ? square_home_qty + (target - square_qty) : nil,
          square_variation_id: square_variation_id,
          derived: size_skus.include?(sku.downcase),
          image_url: variant.product&.featuredImageUrl,
        )
      end
      rows
    end

    def actionable_rows(rows, skus: nil)
      rows.select do |row|
        sku_match = skus.blank? || skus.any? { |sku| sku.to_s.downcase == row.sku.downcase }
        sku_match && !row.target.nil? && row.tracked && row.square_variation_id.present? &&
          !row.derived && !shared_skus.include?(row.sku.to_s.downcase) &&
          !multiloc_skus.include?(row.sku.to_s.downcase) &&
          (row.shopify_delta != 0 || row.square_delta != 0)
      end
    end

    # SKUs linked to more than one Shopify variant can't be reconciled against a
    # single Square variation — mirrors the InventoryMaintainer's shared_skus
    # guard so the Reconcile UI never proposes (or half-applies) an ambiguous
    # shared-pool write.
    def shared_skus
      @shared_skus ||= SkuLink.shared_skus
    end

    # A Square variation with stock in more than one Square location can't be
    # represented by a single home PHYSICAL_COUNT, so it's not reconcilable.
    # Mirrors the InventoryMaintainer's multiloc guard; without this the
    # reconciled home target can go negative and the PlanApplier preflight
    # would block the entire apply on one un-reconcilable SKU.
    def multiloc_skus
      @multiloc_skus ||= begin
        ids = InventoryLevel.where(source: "square", quantity: 1..)
          .group(:squareVariationId).having("count(DISTINCT \"locationId\") > 1")
          .pluck(:squareVariationId)
        SkuLink.where(squareVariationId: ids).pluck(:sku).map(&:downcase).to_set
      end
    end

    def summary(rows)
      candidates = actionable_rows(rows)
      drift_count = rows.count { |row| !row.target.nil? && row.drift != 0 && row.tracked && row.square_variation_id.present? && !row.derived }
      # Only the rows we would actually write can be "blocked by a negative
      # Square home count" — shared/multiloc/derived rows aren't candidates.
      blocked = candidates.count { |row| row.square_delta && !row.square_home_target.nil? && row.square_home_target.negative? }
      { total: rows.length, drift_count: drift_count, actionable: candidates.length, blocked_adjustments: blocked, derived: rows.count(&:derived) }
    end

    def record_run!(rows, mode:)
      run = ReconcileRun.create!(
        mode: mode,
        status: "pending",
        totalRows: rows.length,
        actionable: actionable_rows(rows).length,
        applied: 0,
        failed: 0,
        startedAt: Time.current,
      )
      unless rows.empty?
        # Bulk insert (one statement instead of N create! calls); the legacy
        # HasCuid id format is reproduced inline because callbacks are skipped.
        ReconcileItem.insert_all(
          rows.map do |row|
            {
              id: new_cuid,
              runId: run.id,
              sku: row.sku,
              product: row.product,
              variant: row.variant,
              tracked: row.tracked,
              priority: row.priority,
              shopifyQty: row.shopify_qty,
              squareQty: row.square_qty,
              target: row.target,
              drift: row.drift,
              shopifyDelta: row.shopify_delta,
              squareDelta: row.square_delta,
              ok: nil,
              actions: nil,
              tenant_id: Current.tenant_id,
            }
          end,
          unique_by: :id,
        )
      end
      prune_old_runs!
      run
    end

    # ReconcileRun grows by one row per sync (~96/day) with a ReconcileItem per
    # SKU each time; keep the last 30 days and drop the rest so the table
    # doesn't grow without bound.
    def prune_old_runs!(keep: 30.days)
      cutoff = Time.current - keep
      old_ids = ReconcileRun.unscoped.where(tenant_id: Current.tenant_id)
        .where('"startedAt" < ?', cutoff).pluck(:id)
      return if old_ids.empty?

      ReconcileItem.unscoped.where(runId: old_ids).delete_all
      ReconcileRun.unscoped.where(id: old_ids).delete_all
    end

    def new_cuid
      "c#{Time.now.to_i.to_s(36)}#{SecureRandom.alphanumeric(16)}"
    end

    def compute_target(priority, shopify_qty, square_qty)
      return if shopify_qty.nil? || square_qty.nil?

      target = case priority
      when "square" then square_qty
      when "shopify" then shopify_qty
      else [shopify_qty, square_qty].min
      end
      [target, 0].max
    end
  end
end
