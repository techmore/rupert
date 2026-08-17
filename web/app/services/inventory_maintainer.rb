# frozen_string_literal: true

# The 15-minute market-sync step (runs inside the sync loop).
#
# Rupert is the source of truth. The anchor is the manual physical count the
# shop entered into Square (2026-08-13/14); after that, every sale on EITHER
# platform consumes the shared pool for that SKU:
#
#   pool = Square's current count − units sold online (Shopify) since the last
#          time Square was brought to the pool
#
# Square's mirror already reflects in-store sales, so the only thing Square
# hasn't accounted for is online volume. Each cycle pushes the pool to BOTH
# markets (Shopify via AdjustInventory, Square via PHYSICAL_COUNT at the home
# location) so they stay in lock-step until the next manual count re-anchors.
#
# The online-sales watermark prevents double-counting: online sales are folded
# once, and only until they've been pushed into Square's count. After a cycle
# that writes Square, the watermark advances so those same sales aren't
# subtracted again.
#
# Size-family SKUs are excluded here — SizeDeriver derives their targets from
# the root gram bank (approval mode stages pending changes; auto mode applies).
# Unlinked SKUs on either platform are skipped and reported, never created
# (SKU changes are still frozen by policy).
class InventoryMaintainer
  SHOPIFY_ADJUST_QUERY = <<~GRAPHQL
    mutation AdjustInventory($input: InventoryAdjustQuantitiesInput!, $idempotencyKey: String!) {
      inventoryAdjustQuantities(input: $input) @idempotent(key: $idempotencyKey) {
        inventoryAdjustmentGroup { createdAt changes { name delta } }
        userErrors { field message }
      }
    }
  GRAPHQL

  SHOPIFY_LEVEL_QUERY = <<~GRAPHQL
    query ShopifyLevel($inventoryItemId: ID!, $locationId: ID!) {
      inventoryItem(id: $inventoryItemId) {
        id
        inventoryLevel(locationId: $locationId) {
          id
          quantities(names: ["available"]) { name quantity }
        }
      }
    }
  GRAPHQL

  POOL_WATERMARK_KEY = "pool_online_watermark_at"

  class << self
    def run!(actor: "system")
      watermark = online_watermark
      family_skus = SizeFamilyMember.pluck(:sku).map { |s| s.to_s.downcase }.to_set
      # One Shopify SKU mapping to multiple variants (e.g. DSLR1 = 5 strains)
      # can't be reconciled against a single Square variation — skip, report only.
      shared_skus = SkuLink.linked.group(:sku).distinct.count("shopifyVariantId")
        .select { |_, count| count > 1 }.keys.map(&:downcase).to_set
      square_totals = InventoryLevel.where(source: "square").group(:squareVariationId).sum(:quantity)
      online_sold = Core::OrderLine.joins(:order)
        .where(orders: { source: "shopify", occurred_at: watermark..Time.current })
        .group(:sku).sum(:quantity)
      shopify_location = Location.where(source: "shopify").order(:syncedAt).first
      home = SquareSyncer.primary_location_id

      summary = {
        watermark: watermark, linked: 0, shopify_pushed: 0, square_pushed: 0,
        noop: 0, skipped_unlinked: 0, failed: 0, families: nil, results: [],
      }

      SkuLink.linked.includes(:shopify_variant).each do |link|
        summary[:linked] += 1
        sku = link.sku.to_s
        variant = link.shopify_variant
        next if family_skus.include?(sku.downcase)
        next if shared_skus.include?(sku.downcase)

        if variant.nil? || !variant.tracked || variant.inventoryItemId.blank? || shopify_location.nil?
          summary[:skipped_unlinked] += 1
          next
        end

        square_qty = square_totals.fetch(link.squareVariationId, 0).to_i
        pool = [square_qty - online_sold.fetch(sku, 0).to_i, 0].max
        notes = []
        ok = true

        current = variant.inventoryQuantity.to_i
        delta = pool - current
        unless delta.zero?
          begin
            actual = shopify_level(variant.inventoryItemId, shopify_location.externalId)
            if actual == pool
              summary[:noop] += 1
            else
              actual_delta = pool - actual
              push_shopify!(variant, actual, actual_delta, shopify_location)
              journal(link, variant.id, actual, pool, actual_delta, "shopify")
              summary[:shopify_pushed] += 1
              notes << "Shopify #{actual_delta.positive? ? "+" : ""}#{actual_delta}"
            end
          rescue StandardError => e
            ok = false
            notes << "Shopify ✕ #{e.message}"
          end
        end

        if link.squareVariationId.present? && home.present? && pool != square_qty && !PlatformPushGuard.frozen?("square")
          begin
            PlatformPushGuard.authorize!("square", actor: "system")
            SquareClient.request("/inventory/changes/batch-create", method: "POST", body: {
              idempotency_key: "hh-pool-#{sku.gsub(/[^a-z0-9]/i, "").slice(0, 40)}-#{link.squareVariationId}-#{pool}-#{Time.current.to_i}",
              changes: [{
                type: "PHYSICAL_COUNT",
                physical_count: {
                  reference_id: "hh-pool-#{sku}",
                  catalog_object_id: link.squareVariationId,
                  state: "IN_STOCK",
                  location_id: home.externalId,
                  quantity: pool.to_s,
                  occurred_at: Time.current.iso8601,
                },
              }],
              ignore_unchanged_counts: true,
            })
            journal(link, nil, square_qty, pool, pool - square_qty, "square")
            summary[:square_pushed] += 1
            notes << "Square → #{pool}"
          rescue StandardError => e
            ok = false
            notes << "Square ✕ #{e.message}"
          end
        end

        if notes.empty?
          summary[:noop] += 1
        else
          summary[:results] << { sku: sku, actions: notes, pool: pool, square_qty: square_qty, online_sold: online_sold.fetch(sku, 0) }
        end
        summary[:failed] += 1 unless ok
      end

      # Online sales up to now are baked into Square's counts, so the next
      # cycle must only fold sales after this moment.
      if summary[:square_pushed].positive?
        Setting.create_with(value: Time.current.iso8601)
          .find_or_create_by!(key: POOL_WATERMARK_KEY, tenant_id: Current.tenant_id)
          .update!(value: Time.current.iso8601)
      end

      # Publish what was adjusted and why to the inv_adjustments channel.
      publish_adjustments(summary) if summary[:results].any?

      summary[:families] = SizeDeriver.process_all! if SizeFamily.any?
      summary
    end

    private

    # Publish the run's adjustments to the inv_adjustments channel, falling back
    # to the main Buzz channel until BUZZ_INV_ADJUSTMENTS_CHANNEL is set.
    def publish_adjustments(summary)
      channel = EnvStore.fetch("BUZZ_INV_ADJUSTMENTS_CHANNEL", "").presence || BuzzAgent.channel_id
      BuzzNotifyJob.perform_later(adjustment_message(summary), channel: channel, tags: [["t", "inventory"]])
    end

    def adjustment_message(summary)
      lines = summary[:results].map do |result|
        why = "Square #{result[:square_qty]}"
        why += ", #{result[:online_sold]} online" if result[:online_sold].to_i.positive?
        why += " → pool #{result[:pool]}"
        "  • #{result[:sku]}: #{Array(result[:actions]).join("; ")} · #{why}"
      end
      head = "Inventory adjustments — #{Time.current.in_time_zone("America/New_York").strftime("%H:%M %Z")}"
      head += " · #{summary[:failed]} failed" if summary[:failed].to_i.positive?
      "#{head}\n#{lines.join("\n")}"
    end

    # The online-sales watermark. First run initializes it to the earliest
    # successful sync on the day of the manual count (Square was updated last
    # night), so every online sale after the count folds in exactly once.
    def online_watermark
      existing = Setting.find_by(key: POOL_WATERMARK_KEY, tenant_id: Current.tenant_id)&.value
      return Time.zone.parse(existing) if existing.present?

      watermark = SyncRun.where(status: "success", tenant_id: Current.tenant_id)
        .where('"startedAt" >= ?', Time.current.beginning_of_day).minimum(:startedAt) ||
        Time.current.beginning_of_day
      Setting.create_with(value: watermark.iso8601)
        .find_or_create_by!(key: POOL_WATERMARK_KEY, tenant_id: Current.tenant_id)
      watermark
    end

    def push_shopify!(variant, current, delta, location)
      PlatformPushGuard.authorize!("shopify", actor: "system")
      slug = variant.sku.to_s.gsub(/[^a-z0-9]/i, "").slice(0, 40)
      slug = "item" if slug.blank?
      response = ShopifyClient.graphql(SHOPIFY_ADJUST_QUERY, {
        input: {
          reason: "correction",
          name: "available",
          referenceDocumentUri: "herbal-healers://inventory/pool-sync",
          changes: [{
            delta: delta,
            changeFromQuantity: current,
            inventoryItemId: variant.inventoryItemId,
            locationId: location.externalId,
          }],
        },
        idempotencyKey: "hh-pool-#{slug}-#{variant.id}-#{delta}",
      })
      user_errors = response.dig("inventoryAdjustQuantities", "userErrors") || []
      raise ShopifyClient::Error, user_errors.map { |i| i["message"] }.join("; ") if user_errors.any?

      true
    end

    # Reads the actual available quantity at the location straight from Shopify,
    # so AdjustInventory's changeFromQuantity always matches what's persisted.
    def shopify_level(inventory_item_id, location_id)
      response = ShopifyClient.graphql(SHOPIFY_LEVEL_QUERY, {
        inventoryItemId: inventory_item_id,
        locationId: location_id,
      })
      response.dig("inventoryItem", "inventoryLevel", "quantities")&.first&.dig("quantity").to_i
    end

    def journal(link, variant_id, before, after, delta, platform)      InventoryMovement.create!(
        sku: link.sku,
        shopifyVariantId: variant_id,
        squareVariationId: platform == "square" ? link.squareVariationId : nil,
        source: "maintain",
        direction: delta.negative? ? "out" : "in",
        delta: delta,
        quantityBefore: before,
        quantityAfter: after,
        reason: "Shared-pool sync",
        reference: "inventory-maintainer",
        actor: "system",
        createdAt: Time.current,
      )
    end
  end
end
