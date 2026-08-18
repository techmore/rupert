# frozen_string_literal: true

# Single owner of the outbound inventory-write payloads used across the sync
# pipeline:
#
#   * Shopify AdjustInventory mutation — the same GraphQL document was embedded
#     in InventoryMaintainer, SizeDeriver and PlanApplier, each with its own
#     copy of the userErrors check.
#   * Square PHYSICAL_COUNT batch-create bodies — InventoryMaintainer,
#     SizeDeriver, PlanApplier and NegativeInventory all built the identical
#     four-field payload by hand.
#   * The SKU -> slug sanitization shared by every idempotency-key formula.
#
# Platform payload drift between these callers was the recurring bug class, so
# the mutation, the payload shape and the key-slug rules live here once.
class InventoryWriter
  ADJUST_QUERY = <<~GRAPHQL
    mutation AdjustInventory($input: InventoryAdjustQuantitiesInput!, $idempotencyKey: String!) {
      inventoryAdjustQuantities(input: $input) @idempotent(key: $idempotencyKey) {
        inventoryAdjustmentGroup { createdAt changes { name delta } }
        userErrors { field message }
      }
    }
  GRAPHQL

  SQUARE_COUNT_PATH = "/inventory/changes/batch-create"

  class << self
    # Adjust one Shopify variant's "available" quantity at a location. Callers
    # pass their own idempotency key (see per_run_key); change_from is the
    # persisted quantity Shopify expects as changeFromQuantity when known.
    def adjust_shopify!(inventory_item_id:, delta:, location:, reference:, idempotency_key:, change_from: nil)
      change = { delta: delta, inventoryItemId: inventory_item_id, locationId: location.externalId }
      change[:changeFromQuantity] = change_from if change_from.present?

      response = ShopifyClient.graphql(ADJUST_QUERY, {
        input: {
          reason: "correction",
          name: "available",
          referenceDocumentUri: "herbal-healers://inventory/#{reference}",
          changes: [change],
        },
        idempotencyKey: idempotency_key,
      })

      user_errors = response.dig("inventoryAdjustQuantities", "userErrors") || []
      raise ShopifyClient::Error, user_errors.map { |e| e["message"] }.join("; ") if user_errors.any?

      true
    end

    # One Square PHYSICAL_COUNT write at a single location. The shared-pool
    # design writes the home-base location; NegativeInventory writes the
    # offending level's own location. Idempotency key + reference_id are
    # caller-chosen so retries within a run stay stable.
    def physical_count!(catalog_object_id:, quantity:, location:, reference_id:, idempotency_key:)
      SquareClient.request(SQUARE_COUNT_PATH, method: "POST", body: {
        idempotency_key: idempotency_key,
        changes: [{
          type: "PHYSICAL_COUNT",
          physical_count: {
            reference_id: reference_id,
            catalog_object_id: catalog_object_id,
            state: "IN_STOCK",
            location_id: location.externalId,
            quantity: quantity.to_s,
            occurred_at: Time.current.iso8601,
          },
        }],
        ignore_unchanged_counts: true,
      })
    end

    # SKU -> URL-safe idempotency slug. Shopify keeps idempotency keys for a
    # long time, so keys must be predictable but distinct per logical write.
    def slugify(sku)
      slug = sku.to_s.gsub(/[^a-z0-9]/i, "").slice(0, 40)
      slug.presence || "item"
    end

    # Idempotency key for a recurring (variant, delta, starting-qty) adjust: a
    # per-run token keeps each distinct adjustment on its own key while staying
    # stable for retries within a run.
    def per_run_key(prefix, sku, id, current, delta)
      "#{prefix}-#{slugify(sku)}-#{id}-#{Current.sync_run_id.presence || Time.current.to_i}-#{current}->#{delta}"
    end
  end
end
