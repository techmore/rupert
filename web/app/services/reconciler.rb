# frozen_string_literal: true

# Port of reconcilePlan + seedReconcilePlan from the legacy console — builds
# the SKU-level reconciliation plan from the mirrored database and records
# each plan as a ReconcileRun.
class Reconciler
  PRIORITIES = %w[lowest shopify square].freeze

  Row = Struct.new(
    :sku, :product, :variant, :variant_id, :inventory_item_id, :tracked,
    :priority, :shopify_qty, :square_qty, :square_home_qty, :target,
    :drift, :shopify_delta, :square_delta, :square_home_target,
    :square_variation_id, keyword_init: true
  )

  class << self
    def build_rows
      policies = InventoryPolicy.all.to_h { |p| [p.sku.downcase, p.priority] }
      home_location_id = SquareSyncer.primary_location_id
      links = SkuLink.linked.index_by(&:shopifyVariantId)

      rows = []
      ShopifyVariant.includes(:product).where.not(sku: [nil, ""]).where(tracked: true).find_each do |variant|
        sku = variant.sku.to_s.strip
        next if sku.empty?

        link = links[variant.id]
        square_variation_id = link&.squareVariationId

        shopify_qty = variant.inventoryQuantity
        square_qty = nil
        square_home_qty = nil
        if square_variation_id.present?
          square_qty = InventoryLevel.total_for_variation(square_variation_id)
          square_home_qty = home_location_id ? InventoryLevel.where(source: "square",
            locationId: home_location_id, squareVariationId: square_variation_id).sum(:quantity) : nil
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
          drift: shopify_qty != nil && square_qty != nil ? square_qty - shopify_qty : nil,
          shopify_delta: target != nil && shopify_qty != nil ? target - shopify_qty : nil,
          square_delta: target != nil && square_qty != nil ? target - square_qty : nil,
          square_home_target: target != nil && square_qty != nil && square_home_qty != nil ? square_home_qty + (target - square_qty) : nil,
          square_variation_id: square_variation_id
        )
      end
      rows
    end

    def actionable_rows(rows, skus: nil)
      rows.select do |row|
        sku_match = skus.blank? || skus.any? { |sku| sku.to_s.downcase == row.sku.downcase }
        sku_match && row.target != nil && row.tracked && row.square_variation_id.present? &&
          (row.shopify_delta != 0 || row.square_delta != 0)
      end
    end

    def summary(rows)
      blocked = rows.count { |row| row.square_delta && row.square_home_target != nil && row.square_home_target.negative? }
      drift_count = rows.count { |row| row.target != nil && row.drift != 0 && row.tracked && row.square_variation_id.present? }
      { total: rows.length, drift_count: drift_count, actionable: actionable_rows(rows).length, blocked_adjustments: blocked }
    end

    def record_run!(rows, mode:)
      run = ReconcileRun.create!(
        mode: mode, status: "pending", totalRows: rows.length,
        actionable: actionable_rows(rows).length, applied: 0, failed: 0,
        startedAt: Time.current
      )
      rows.each do |row|
        ReconcileItem.create!(
          runId: run.id, sku: row.sku, product: row.product, variant: row.variant,
          tracked: row.tracked, priority: row.priority,
          shopifyQty: row.shopify_qty, squareQty: row.square_qty,
          target: row.target, drift: row.drift,
          shopifyDelta: row.shopify_delta, squareDelta: row.square_delta,
          ok: nil, actions: nil
        )
      end
      run
    end

    def compute_target(priority, shopify_qty, square_qty)
      return nil if shopify_qty.nil? || square_qty.nil?

      target = case priority
               when "square" then square_qty
               when "shopify" then shopify_qty
               else [shopify_qty, square_qty].min
               end
      [target, 0].max
    end
  end
end
