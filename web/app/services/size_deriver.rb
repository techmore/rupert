# frozen_string_literal: true

# Derives the "theoretical" size quantities for a SizeFamily from its root
# gram bank. Every run:
#   1. Ensures base_grams exists (initialized from the root SKU's Square count
#      on the first run, otherwise set manually via the family's root override).
#   2. Folds in grams sold since the last watermark (canonical sales from BOTH
#      platforms, each member size sale weighted by its grams) so root_grams
#      tracks real sales.
#   3. Computes each member's target = floor(root_grams / member.grams).
#   4. Records pending SizeChanges (approval mode) or applies them to Square and
#      Shopify immediately (auto mode).
class SizeDeriver
  SALES_OVERLAP = 10.minutes

  SHOPIFY_ADJUST_QUERY = <<~GRAPHQL
    mutation AdjustInventory($input: InventoryAdjustQuantitiesInput!, $idempotencyKey: String!) {
      inventoryAdjustQuantities(input: $input) @idempotent(key: $idempotencyKey) {
        inventoryAdjustmentGroup { createdAt changes { name delta } }
        userErrors { field message }
      }
    }
  GRAPHQL

  class << self
    def process_all!
      summary = { families: 0, applied: 0, pending: 0, failed: 0 }
      SizeFamily.find_each do |family|
        result = process(family)
        summary[:families] += 1
        summary[:applied] += result[:applied]
        summary[:pending] += result[:pending]
        summary[:failed] += result[:failed]
      rescue StandardError => e
        summary[:failed] += 1
        Rails.logger.error("[SizeDeriver] #{family&.name || "family"} failed: #{e.class}: #{e.message}")
      end
      summary
    end

    # Compute targets and act according to the family's mode. Returns a summary
    # hash plus the build result so callers can render it.
    def process(family)
      result = build(family)
      if family.auto?
        apply!(result)
      else
        record_pending!(result)
      end
      summary = { applied: result[:applied] || 0, pending: result[:pending] || 0, failed: result[:failed] || 0 }
      summary.merge(build: result)
    end

    def build(family)
      ensure_base!(family)
      sold = grams_sold_since(family)
      root_grams = [(family.base_grams.to_f - sold), 0].max

      proposals = family.members.order(:grams).map do |member|
        variation_id = resolve_variation_id!(member)
        current = variation_id.present? ? InventoryLevel.total_for_variation(variation_id) : nil
        target = (root_grams / member.grams.to_f).floor
        {
          member: member,
          target: target,
          current: current,
          needed: current.nil? || target != current,
        }
      end

      { family: family, root_grams: root_grams, grams_sold: sold, proposals: proposals }
    end

    # Apply the current build to Square. Auto mode calls this directly; the
    # Reconcile screen calls it to approve a family's pending changes.
    def apply!(result)
      result[:applied] = 0
      result[:failed] = 0
      result[:proposals].each do |proposal|
        next unless proposal[:needed]

        change = SizeChange.find_or_initialize_by(family_id: result[:family].id, sku: proposal[:member].sku)
        change.tenant_id = Current.tenant_id
        change.grams = proposal[:member].grams
        change.root_grams = result[:root_grams]
        change.target_quantity = proposal[:target]
        change.square_variation_id = proposal[:member].square_variation_id
        change.mode = result[:family].mode
        change.save!

        if apply_change!(change)
          result[:applied] += 1
        else
          result[:failed] += 1
        end
      end
      result
    end

    # Approve a single pending SizeChange: write its target to Square.
    def approve_change!(change)
      result = apply_change!(change)
      { ok: result, change: change }
    end

    # Write one size's target quantity to Square (physical count at the home
    # location) AND to every linked Shopify variant, journaling each movement.
    # Returns true/false; the change records per-platform results as its error.
    def apply_change!(change)
      target = change.target_quantity.to_i
      home = SquareSyncer.primary_location_id
      notes = []
      ok = true

      # Shopify: push the derived target to every linked variant of this SKU.
      if change.sku.present?
        SkuLink.where(sku: change.sku).includes(:shopify_variant).each do |link|
          variant = link.shopify_variant
          next unless variant&.tracked && variant.inventoryItemId.present?

          current = variant.inventoryQuantity.to_i
          delta = target - current
          next if delta.zero?

          begin
            push_shopify!(variant, current, delta)
            journal_movement(change, variant_id: variant.id, before: current, after: target, platform: "shopify", delta: delta)
            notes << "Shopify #{delta.positive? ? "+" : ""}#{delta}"
          rescue StandardError => e
            ok = false
            notes << "Shopify ✕ #{e.message}"
          end
        end
      end

      # Square: physical count at the home location (skipped while frozen).
      if change.square_variation_id.present? && home.present? && !PlatformPushGuard.frozen?("square")
        PlatformPushGuard.authorize!("square", actor: "system")
        before = InventoryLevel.total_for_variation(change.square_variation_id)
        begin
          SquareClient.request("/inventory/changes/batch-create", method: "POST", body: {
            idempotency_key: "hh-size-#{change.sku}-#{change.id}",
            changes: [{
              type: "PHYSICAL_COUNT",
              physical_count: {
                reference_id: "hh-size-#{change.sku}",
                catalog_object_id: change.square_variation_id,
                state: "IN_STOCK",
                location_id: home.externalId,
                quantity: target.to_s,
                occurred_at: Time.current.iso8601,
              },
            }],
            ignore_unchanged_counts: true,
          })
          journal_movement(change, before: before, after: target, platform: "square", delta: target - before)
          notes << "Square → #{target}"
        rescue StandardError => e
          ok = false
          notes << "Square ✕ #{e.message}"
        end
      end

      if ok
        change.update!(status: "applied", error: notes.join(", ").presence)
      else
        change.update!(status: "failed", error: notes.join(", ").presence)
      end
      ok
    end

    private

    def push_shopify!(variant, current, delta)
      PlatformPushGuard.authorize!("shopify", actor: "system")
      location = Location.shopify_primary
      raise ShopifyClient::Error, "No Shopify location" if location.nil?

      slug = variant.sku.to_s.gsub(/[^a-z0-9]/i, "").slice(0, 40)
      slug = "item" if slug.blank?
      response = ShopifyClient.graphql(SHOPIFY_ADJUST_QUERY, {
        input: {
          reason: "correction",
          name: "available",
          referenceDocumentUri: "herbal-healers://inventory/size-derive",
          changes: [{
            delta: delta,
            changeFromQuantity: current,
            inventoryItemId: variant.inventoryItemId,
            locationId: location.externalId,
          }],
        },
        idempotencyKey: "hh-size-#{slug}-#{variant.id}-#{delta}",
      })
      user_errors = response.dig("inventoryAdjustQuantities", "userErrors") || []
      raise ShopifyClient::Error, user_errors.map { |i| i["message"] }.join("; ") if user_errors.any?

      true
    end

    def journal_movement(change, variant_id: nil, before:, after:, platform:, delta:)
      InventoryMovement.create!(
        sku: change.sku,
        shopifyVariantId: variant_id,
        squareVariationId: platform == "square" ? change.square_variation_id : nil,
        source: "size-derive",
        direction: delta.negative? ? "out" : "in",
        delta: delta,
        quantityBefore: before,
        quantityAfter: after,
        reason: "Derived size from root grams",
        reference: "size-family-#{change.family_id}",
        actor: "system",
        createdAt: Time.current,
      )
    end

    def ensure_base!(family)
      if family.base_grams.nil? && family.root_sku.present?
        root_variation = SquareVariation.find_by(sku: family.root_sku)
        family.base_grams = root_variation ? InventoryLevel.total_for_variation(root_variation.id) : nil
      end
      family.sales_watermark ||= Time.current
      family.save!
    end

    def resolve_variation_id!(member)
      return member.square_variation_id if member.square_variation_id.present?

      variation = SquareVariation.find_by(sku: member.sku)
      if variation
        member.square_variation_id = variation.id
        member.save!
      end
      member.square_variation_id
    end

    # Folds in grams sold since the last watermark from the canonical order
    # store, which captures sales from BOTH platforms (Square + Shopify). Each
    # member size is weighted by its grams; the root SKU counts as 1g per unit.
    # Square order lines record the variation *name* as their sku, so the
    # lookup keys on both the member SKU and the Square variation name.
    def grams_sold_since(family)
      return 0.0 if family.sales_watermark.nil?

      lookup = grams_lookup(family)
      return 0.0 if lookup.empty?

      since = family.sales_watermark - SALES_OVERLAP
      sold = 0.0
      Core::OrderLine.joins(:order)
        .where(orders: { occurred_at: since..Time.current })
        .where.not(sku: nil)
        .find_each do |line|
          grams = lookup[line.sku.to_s.downcase]
          next if grams.nil?

          sold += line.quantity.to_i * grams
        end

      family.update!(sales_watermark: Time.current)
      sold.round(3)
    end

    def grams_lookup(family)
      lookup = {}
      family.members.each do |member|
        grams = member.grams.to_f
        lookup[member.sku.to_s.downcase] = grams
        variation = member.square_variation_id.present? ?
          SquareVariation.find_by(id: member.square_variation_id) : SquareVariation.find_by(sku: member.sku)
        lookup[variation.name.to_s.downcase] = grams if variation
        lookup[variation.sku.to_s.downcase] = grams if variation && variation.sku.present?
      end
      if family.root_sku.present?
        lookup[family.root_sku.to_s.downcase] = 1.0
        root = SquareVariation.find_by(sku: family.root_sku)
        lookup[root.name.to_s.downcase] = 1.0 if root
      end
      lookup
    end

    def record_pending!(result)
      family = result[:family]
      applicable = result[:proposals].select { |proposal| proposal[:needed] }

      family.size_changes.pending.find_each do |change|
        next if applicable.any? { |proposal| proposal[:member].sku.casecmp?(change.sku) }

        change.update!(status: "skipped")
      end

      applicable.each do |proposal|
        change = SizeChange.find_or_initialize_by(family_id: family.id, sku: proposal[:member].sku)
        change.tenant_id = Current.tenant_id
        change.grams = proposal[:member].grams
        change.root_grams = result[:root_grams]
        change.target_quantity = proposal[:target]
        change.square_variation_id = proposal[:member].square_variation_id
        change.status = "pending"
        change.mode = "approval"
        change.error = nil
        change.save!
      end

      result[:pending] = applicable.length
      result
    end
  end
end
