# frozen_string_literal: true

require "set"

# Applies the Square SKU remediation plan agreed from the audit, in two kinds of
# work:
#
#   A) LINKING (DB-only, safe/reversible): create SkuLink rows that connect
#      Square variations to Shopify variants. Never touches Square or Shopify.
#
#   B) SQUARE CATALOG WRITES (live, irreversible): assign SKUs to variations
#      that have none, and fix the one duplicate SKU. Uses UpsertCatalogObject
#      (POST /v2/catalog/object), which is full-replacement, so each payload is
#      built by re-stating the object's COMPLETE current data + the new SKU.
#      A fresh RetrieveCatalogObject is read immediately before each write so
#      the `version` is current (optimistic concurrency).
#
# Dry-run first: `build_plan!` returns the full plan (including exact Square
# payloads) without writing. `apply!` refuses to run unless every Square write
# has an approved push window and `ENV['CONFIRM_REMEDIATION'] == 'yes'`.
class SquareSkuRemediator
  STOP = %w[count pack pack single regular thc mg cbd box bottle jar bag default gram grams ct g oz].freeze
  DUP_SKU = "388062y"

  attr_reader :plan

  def self.build_plan!
    new.build_plan!
  end

  # Convenience: build and apply in one step (for the rake apply task).
  def self.apply!(confirmed: ENV["CONFIRM_REMEDIATION"] == "yes")
    r = new
    r.build_plan!
    r.apply!(confirmed: confirmed)
  end

  def build_plan!
    live = SquareClient.catalog
    loc = SquareClient.locations.map { |l| l["id"] }
    counts = loc.any? ? SquareClient.inventory_counts(loc, live.map { |v| v[:variationId] })[:counts] : {}
    items = live.group_by { |v| v[:itemId] }

    links        = build_links(live, items, counts)              # DB-only
    sku_writes   = build_sku_writes(live, counts)                # Square writes (all no-SKU)
    dup_fix      = build_duplicate_fix(live)

    @plan = {
      dry_run: true,
      generated_at: Time.current,
      links_to_create: links,
      sku_assignments: sku_writes,
      duplicate_fix: dup_fix,
      square_paths: sku_writes + (dup_fix ? [dup_fix] : []),
      summary: {
        links: links.length,
        sku_assignments: sku_writes.length,
        duplicate_fix: dup_fix ? 1 : 0,
      },
    }
  end

  # Executes the plan. Refuses without explicit confirmation + a push window.
  def apply!(confirmed: ENV["CONFIRM_REMEDIATION"] == "yes")
    raise "Call build_plan! first" if @plan.nil?
    raise "Applying requires ENV['CONFIRM_REMEDIATION']=yes (review the dry-run first)" unless confirmed

    result = { links_created: 0, sku_updated: 0, sku_errors: [], dup_fixed: false, dup_error: nil }

    @plan[:links_to_create].each do |rec|
      link_sku = rec[:shopify].sku.presence || rec[:square][:sku].presence || rec[:shopify].title
      SkuLink.find_or_create_by!(
        sku: link_sku,
        shopifyVariantId: rec[:shopify].id,
        squareVariationId: rec[:square][:variationId],
        tenant_id: Current.tenant_id,
      ) do |l|
        l.auto = false
        l.matchSource = "audit-link"
      end
      result[:links_created] += 1
    end

    # Square writes, each individually gated and freshly versioned.
    @plan[:square_paths].each do |w|
      guard_square!
      begin
        upsert_one(w)
        result[:sku_updated] += 1 if w[:kind] == "sku"
        result[:dup_fixed] = true if w[:kind] == "dup"
      rescue StandardError => e
        if w[:kind] == "dup"
          result[:dup_error] = e.message
        else
          result[:sku_errors] << "#{w[:variation][:variationId]}: #{e.message}"
        end
      end
    end

    result
  end

  private

  def nn(s)
    s.to_s.downcase.gsub(/[^a-z0-9]+/, " ").strip
  end

  # ---- A) Links (DB-only) ----------------------------------------------------

  def build_links(live, items, counts)
    linked = SkuLink.where(tenant_id: Current.tenant_id).select(&:linked?).map(&:squareVariationId).to_set
    linked_shopify = SkuLink.where(tenant_id: Current.tenant_id).select(&:linked?).map(&:shopifyVariantId).to_set
    shopify = ShopifyVariant.where(tenant_id: Current.tenant_id).includes(:product).to_a

    recs = []
    live.select { |v| !linked.include?(v[:variationId]) && counts[v[:variationId]].to_i.positive? }.each do |v|
      item_name = items[v[:itemId]]&.first&.[](:name).to_s

      # Only auto-link variations whose OWN name is distinctive (not a bare
      # size/count like "3.5 Grams" / "3 Count" / "Regular"), to avoid
      # strapping the wrong strain onto a generic flower-size row.
      own_words = (nn(v[:name]).split(" ") - STOP)
      next if own_words.none? { |w| w.match?(/[a-z]/) } # require a real word, not "3"/"5"

      combined_words = nn([item_name, v[:name]].join(" ")).split(" ") - STOP
      best, score = best_match(shopify, combined_words)
      next if best.nil? || score < 3
      next if linked_shopify.include?(best.id)

      recs << { square: v, shopify: best, score: score, item_name: item_name }
    end
    recs
  end

  def best_match(shopify, combined_words)
    best = nil
    best_score = 0
    shopify.each do |sv|
      t = (nn(sv.title).split(" ") - STOP)
      p = (nn(sv.product&.title.to_s).split(" ") - STOP)
      score = (t & combined_words).length + (p & combined_words).length
      next unless score > best_score
      best = sv
      best_score = score
    end
    [best, best_score]
  end

  # ---- B) Square catalog writes ---------------------------------------------

  def build_sku_writes(live, counts)
    taken = SquareVariation.where(tenant_id: Current.tenant_id).where.not(sku: [nil, ""]).pluck(:sku).to_set
    taken.merge(ShopifyVariant.where(tenant_id: Current.tenant_id).where.not(sku: [nil, ""]).pluck(:sku))
    taken = taken.map(&:downcase).to_set

    item_names = {}
    writes = []
    live.select { |v| v[:sku].blank? }.each do |v|
      item = v[:itemId]
      item_names[item] ||= begin
        obj = SquareClient.request("/catalog/object/#{item}")["object"]
        obj.dig("item_data", "name").presence || "item"
      end

      proposed = propose_sku(v, item_names[item], taken)
      taken << proposed.downcase

      full = fetch_full(v[:variationId])
      next if full.nil?
      writes << {
        kind: "sku",
        variation: v,
        item_id: item,
        item_name: item_names[item],
        proposed_sku: proposed,
        qty: counts[v[:variationId]].to_i,
        catalog_object: full,
      }
    end
    writes
  end

  def propose_sku(variation, item_name, taken)
    base = nn("#{item_name}-#{variation[:name]}").gsub(/\s+/, "-")
    base = base[0, 40]
    base = "item-#{variation[:variationId].downcase[0, 6]}" if base.blank?
    candidate = base
    i = 1
    while taken.include?(candidate.downcase) && i < 100
      candidate = "#{base}-#{i}"
      i += 1
    end
    candidate
  end

  def build_duplicate_fix(live)
    dups = live.select { |v| v[:sku].to_s.downcase == DUP_SKU }
    return nil if dups.length < 2

    target = dups[1]
    {
      kind: "dup",
      variation: target,
      item_id: target[:itemId],
      proposed_sku: "#{DUP_SKU}-2",
      catalog_object: fetch_full(target[:variationId]),
    }
  end

  def fetch_full(variation_id)
    SquareClient.request("/catalog/object/#{variation_id}")["object"]
  end

  # Build the exact UpsertCatalogObject POST body: fresh version + full object,
  # with the SKU added and every other field preserved.
  def upsert_one(w)
    full = fetch_full(w[:variation][:variationId])
    raise "variation not found in live catalog" if full.nil? || full["is_deleted"]

    vd = (full["item_variation_data"] || {}).deep_dup
    vd["sku"] = w[:proposed_sku]

    {
      "idempotency_key" => "hh-sku-#{w[:variation][:variationId]}-#{full['version']}",
      "object" => full.merge("item_variation_data" => vd),
    }.tap { |body| SquareClient.request("/catalog/object", method: "POST", body: body) }
  end

  def guard_square!
    PlatformPushGuard.authorize!("square", actor: "remediator")
  rescue PlatformPushGuard::LockedError => e
    raise "Square write blocked by push guard: #{e.message}"
  end
end
