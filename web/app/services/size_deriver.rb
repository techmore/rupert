# frozen_string_literal: true

# Derives the "theoretical" size quantities for a SizeFamily from its root
# gram bank. Every run:
#   1. Ensures base_grams exists (initialized from the root SKU's Square count
#      on the first run, otherwise set manually via the family's root override).
#   2. Folds in grams sold since the last watermark (Square orders, each member
#      size sale weighted by its grams) so root_grams tracks real sales.
#   3. Computes each member's target = floor(root_grams / member.grams).
#   4. Records pending SizeChanges (approval mode) or applies them to Square
#      immediately (auto mode).
class SizeDeriver
  SALES_OVERLAP = 10.minutes

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
    # location) and journal the movement. Returns true/false.
    def apply_change!(change)
      home = SquareSyncer.primary_location_id
      if change.square_variation_id.blank? || home.nil?
        change.update!(status: "failed", error: "No linked Square variation or home location")
        return false
      end

      SquareClient.request("/inventory/changes/batch-create", method: "POST", body: {
        idempotency_key: "hh-size-#{change.sku}-#{change.id}",
        changes: [{
          type: "PHYSICAL_COUNT",
          physical_count: {
            reference_id: "hh-size-#{change.sku}",
            catalog_object_id: change.square_variation_id,
            state: "IN_STOCK",
            location_id: home.externalId,
            quantity: change.target_quantity.to_s,
            occurred_at: Time.current.iso8601,
          },
        }],
        ignore_unchanged_counts: true,
      })

      before = InventoryLevel.total_for_variation(change.square_variation_id)
      InventoryMovement.create!(
        sku: change.sku,
        squareVariationId: change.square_variation_id,
        source: "size-derive",
        direction: change.target_quantity.to_i < before ? "out" : "in",
        delta: change.target_quantity.to_i - before,
        quantityBefore: before,
        quantityAfter: change.target_quantity.to_i,
        reason: "Derived size from root grams",
        reference: "size-family-#{change.family_id}",
        actor: "system",
        createdAt: Time.current,
      )
      change.update!(status: "applied", error: nil)
      true
    rescue StandardError => e
      change.update!(status: "failed", error: e.message.to_s[0, 500])
      false
    end

    private

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

    def grams_sold_since(family)
      return 0.0 if family.sales_watermark.nil? || !SquareClient.configured?

      locations = SquareClient.locations
      return 0.0 if locations.empty?

      orders = SquareClient.orders(
        locations.map { |l| l["id"] },
        (family.sales_watermark - SALES_OVERLAP).iso8601,
      )

      grams_map = {}
      family.members.each do |member|
        grams_map[member.square_variation_id] = member.grams.to_f if member.square_variation_id.present?
      end
      if family.root_sku.present?
        root_variation = SquareVariation.find_by(sku: family.root_sku)
        grams_map[root_variation.id] = 1.0 if root_variation
      end

      sold = 0.0
      orders.each do |order|
        Array(order["line_items"]).each do |line_item|
          variation_id = line_item["catalog_object_id"]
          next if variation_id.blank? || !grams_map.key?(variation_id)

          sold += line_item["quantity"].to_i * grams_map[variation_id]
        end
      end

      family.update!(sales_watermark: Time.current)
      sold.round(3)
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
