# frozen_string_literal: true

namespace :ops do
  def load_tenant!
    tenant_id = ENV["TENANT_ID"]
    tenant = tenant_id.present? ? Tenant.find_by(id: tenant_id) : Tenant.where(status: "active").first
    raise "No tenant found (set TENANT_ID or seed one)" if tenant.nil?

    Current.tenant = tenant
  end

  desc "Run a full Shopify + Square sync"
  task sync: :environment do
    load_tenant!
    SyncEngine.run!(mode: "manual", actor: "rake")
    puts "Sync completed"
  end

  desc "Backfill order history: ops:backfill[DAYS] (defaults to SYNC_HISTORY_DAYS or 3650)"
  task :backfill, [:days] => :environment do |_, args|
    load_tenant!
    days = (args[:days] || ENV["SYNC_HISTORY_DAYS"] || "3650").to_i
    SyncEngine.run!(mode: "backfill", actor: "rake", history_days: days)
    puts "Backfill completed (#{days} days)"
  end

  desc "Run a single-source sync: ops:sync_source[shopify|square]"
  task :sync_source, [:source] => :environment do |_, args|
    load_tenant!
    SyncEngine.run_source!(args[:source], actor: "rake")
    puts "#{args[:source]} sync completed"
  end

  desc "Backfill syncRunId on mirror movements from the nearest prior sync run (idempotent)"
  task link_sync_runs: :environment do
    load_tenant!
    runs = SyncRun.unscoped.where(tenant_id: Current.tenant_id, source: "all")
      .order(startedAt: :asc).pluck(:id, :startedAt)
    if runs.empty?
      puts "No sync runs to link against"
      next
    end

    linked = 0
    InventoryMovement.unscoped.where(tenant_id: Current.tenant_id, syncRunId: nil)
      .where(source: ["square", "shopify"]).find_each do |movement|
      run = runs.reverse_each.find { |_, started_at| started_at <= movement.createdAt }
      next if run.nil?

      movement.update_column(:syncRunId, run[0])
      linked += 1
    end
    puts "Linked #{linked} movements to their capturing sync run"
  end

  desc "Seed the standard chart of accounts for the active tenant (idempotent)"
  task chart_of_accounts: :environment do
    load_tenant!
    count = Finance::ChartOfAccounts.seed!
    puts "Chart of accounts seeded (#{count} accounts)"
  end

  desc "Print the reconciliation plan summary"
  task reconcile: :environment do
    load_tenant!
    rows = Reconciler.build_rows
    puts Reconciler.summary(rows).to_json
  end

  desc "Apply the reconciliation plan to Shopify and Square inventory"
  task apply: :environment do
    load_tenant!
    result = PlanApplier.apply!(actor: "rake")
    puts "Applied #{result[:applied]} adjustment(s)"
    result[:results].each do |row|
      puts "#{row[:sku]}: #{row[:ok] ? "ok" : "FAILED"} target=#{row[:target]} #{row[:actions].join("; ")}"
    end
  end

  desc "Dry-run: print the plan for SKUs shared across products (no changes made)"
  task sku_remediation_plan: :environment do
    load_tenant!
    plans = SkuRemediationPlanner.plan
    if plans.empty?
      puts "No shared SKUs found — nothing to plan."
      next
    end

    puts "Shared SKUs -> proposed unique SKUs (apply requires updating Shopify + Square + re-linking):"
    plans.group_by(&:sku).each do |sku, group|
      puts "\n#{sku} (#{group.length} variants):"
      group.each do |plan|
        puts "  #{plan.product.ljust(48)} #{plan.variant_id}  qty=#{plan.current_qty}  ->  #{plan.proposed_sku}"
      end
    end
  end

  desc "Push Square's current totals to Shopify for linked SKUs (Square = source of truth). One-way, idempotent, journaled."
  task push_square_totals: :environment do
    load_tenant!

    query = <<~GRAPHQL
      mutation AdjustInventory($input: InventoryAdjustQuantitiesInput!, $idempotencyKey: String!) {
        inventoryAdjustQuantities(input: $input) @idempotent(key: $idempotencyKey) {
          inventoryAdjustmentGroup { createdAt changes { name delta } }
          userErrors { field message }
        }
      }
    GRAPHQL

    shopify_location = Location.where(source: "shopify").order(:syncedAt).first
    raise "No Shopify location found — cannot write inventory levels" if shopify_location.nil?

    links = SkuLink.linked.includes(:shopify_variant).to_a
    square_totals = InventoryLevel.where(source: "square").group(:squareVariationId).sum(:quantity)

    pushed = 0
    failed = 0
    skipped = 0
    results = []

    links.each do |link|
      variant = link.shopify_variant
      next unless variant&.tracked
      next if variant.inventoryItemId.blank?

      sku = link.sku.to_s
      square_qty = square_totals.fetch(link.squareVariationId, 0).to_i
      target = [square_qty, 0].max
      shopify_qty = variant.inventoryQuantity.to_i
      delta = target - shopify_qty

      if delta == 0
        skipped += 1
        results << { sku: sku, ok: true, target: target, actions: ["no-op"] }
        next
      end

      begin
        slug = sku.gsub(/[^a-z0-9]/i, "").slice(0, 40)
        slug = "item" if slug.blank?
        response = ShopifyClient.graphql(query, {
          input: {
            reason: "correction",
            name: "available",
            referenceDocumentUri: "herbal-healers://inventory/square-as-truth",
            changes: [{
              delta: delta,
              changeFromQuantity: shopify_qty,
              inventoryItemId: variant.inventoryItemId,
              locationId: shopify_location.externalId,
            }],
          },
          idempotencyKey: "hh-s2s-#{slug}-#{variant.id}-#{delta}",
        })
        user_errors = response.dig("inventoryAdjustQuantities", "userErrors") || []
        raise ShopifyClient::Error, user_errors.map { |i| i["message"] }.join("; ") if user_errors.any?

        InventoryMovement.create!(
          sku: sku,
          shopifyVariantId: variant.id,
          squareVariationId: link.squareVariationId,
          source: "reconcile",
          direction: delta.negative? ? "out" : "in",
          delta: delta,
          quantityBefore: shopify_qty,
          quantityAfter: target,
          reason: "Square-as-truth push",
          reference: "push_square_totals",
          actor: "system",
          createdAt: Time.current,
        )
        pushed += 1
        results << { sku: sku, ok: true, target: target, actions: ["Shopify #{delta.positive? ? "+" : ""}#{delta}"] }
      rescue StandardError => e
        failed += 1
        results << { sku: sku, ok: false, target: target, actions: ["Shopify ✕ #{e.message}"] }
      end
    end

    puts JSON.pretty_generate(
      linked: links.length,
      pushed: pushed,
      failed: failed,
      skipped: skipped,
      unmatched_square_variations: SquareVariation.where.not(id: links.map(&:squareVariationId).compact).count,
      unmatched_shopify_variants: ShopifyVariant.where.not(id: links.map(&:shopifyVariantId).compact).count,
      results: results,
    )
  end

  desc "Run the inventory maintenance loop now: Square counts to Shopify (linked SKUs) + size-family derives to both platforms"
  task maintain: :environment do
    load_tenant!
    puts JSON.pretty_generate(InventoryMaintainer.run!(actor: "rake"))
  end

  desc "Seed size families from products labeled the same (group by product title, members derived from Square variation names). Idempotent, approval mode."
  task seed_families: :environment do
    load_tenant!

    square_totals = InventoryLevel.where(source: "square").group(:squareVariationId).sum(:quantity)

    # Candidate memberships: tracked Shopify variants with a SKU, grouped by
    # product title. Grams come from the Square variation name (physical truth),
    # falling back to a numeric prefix in the SKU.
    candidates = ShopifyVariant.where(tracked: true).where.not(sku: [nil, ""]).includes(:product)
      .to_a.group_by { |v| v.product&.title }.filter_map do |title, variants|
      members = variants.filter_map do |v|
        link = SkuLink.find_by(shopifyVariantId: v.id) || SkuLink.find_by(sku: v.sku)
        variation = link ? SquareVariation.find_by(id: link.squareVariationId) : SquareVariation.find_by(sku: v.sku)
        grams = (variation&.name.to_s.match(/\d+(\.\d+)?/))&.[](0)&.to_f
        grams ||= v.sku.to_s.match(/\d+(\.\d+)?/)&.[](0)&.to_f
        next if grams.nil? || grams <= 0

        { sku: v.sku.to_s, grams: grams, square_variation_id: variation&.id, variant_id: v.id }
      end
      next if title.blank? || members.length < 2

      [title, members]
    end

    # Guard: a Square variation shared across two product labels (e.g. the rosin
    # strains share DSLR1/DSLR5 on Square) would make families fight over one
    # variation — skip every family that touches a shared variation.
    variation_use = Hash.new(0)
    candidates.each { |_, members| members.each { |m| variation_use[m[:square_variation_id]] += 1 if m[:square_variation_id] } }
    created = 0
    skipped_shared = 0

    candidates.each do |title, members|
      if members.any? { |m| m[:square_variation_id] && variation_use[m[:square_variation_id]] > 1 }
        skipped_shared += 1
        puts "SKIP #{title} — members share a Square variation used by another product"
        next
      end

      family = SizeFamily.find_or_create_by!(name: title, tenant_id: Current.tenant_id)
      is_new = family.previous_changes["id"].present? || family.created_at_previously_changed?
      family.update!(mode: "approval")
      members.each do |m|
        member = family.members.find_or_initialize_by(sku: m[:sku])
        member.tenant_id = Current.tenant_id
        member.grams = m[:grams]
        member.square_variation_id = m[:square_variation_id]
        member.save!
      end

      base = members.sum { |m| square_totals.fetch(m[:square_variation_id], 0).to_i * m[:grams] }
      family.update!(base_grams: base, sales_watermark: Time.current) if family.base_grams.nil?
      created += 1
      puts "SEED #{title} base_grams=#{family.base_grams} members=#{members.map { |m| "#{m[:sku]}=#{m[:grams]}g" }.join(", ")}"
    end

    puts "families seeded: #{created}, skipped (shared variations): #{skipped_shared}"
  end

  namespace :push_guard do
    desc "Show push-guard status for Shopify and Square (freeze + approval windows)"
    task status: :environment do
      load_tenant!
      PlatformPushGuard.status_all.each do |st|
        state = st[:frozen] ? "FROZEN" : (st[:window_open] ? "window OPEN until #{st[:window_expires_at]}" : "LOCKED")
        puts "#{st[:label].ljust(8)} #{state}"
        puts "  approvals: #{st[:approvals_needed]}/#{st[:approvals_required]} #{st[:approvals].map { |a| a[:email] }.join(", ").presence || "(none)"}"
        puts "  freeze reason: #{st[:freeze_reason].presence || "—"}"
        next if st[:history].empty?

        puts "  recent events:"
        st[:history].last(5).each do |h|
          puts "    #{h["at"]} #{h["action"]} by #{h["by"]}: #{h["detail"]}"
        end
      end
    end

    desc "Record an explicit approval to open a push window: ops:push_guard:approve[square,email] (or APPROVER_EMAIL env)"
    task :approve, [:platform, :email] => :environment do |_, args|
      load_tenant!
      email = args[:email] || ENV["APPROVER_EMAIL"]
      raise "Provide an approver email as the second argument or set APPROVER_EMAIL" if email.blank?

      result = PlatformPushGuard.approve!(args[:platform], email: email)
      if result[:window_open]
        puts "#{PlatformPushGuard.label(args[:platform])} push window OPEN (#{result[:approved_by]}/#{result[:needed]}) until #{result[:window_expires_at]}"
      else
        puts "Approval recorded for #{PlatformPushGuard.label(args[:platform])} — #{result[:approved_by]} of #{result[:needed]} approvals needed."
      end
    end

    desc "Freeze all pushes to a platform (maintenance): ops:push_guard:freeze[square,reason]"
    task :freeze, [:platform, :reason] => :environment do |_, args|
      load_tenant!
      PlatformPushGuard.freeze!(args[:platform], reason: args[:reason], actor: ENV["ACTOR_EMAIL"].presence || "rake")
      puts "#{PlatformPushGuard.label(args[:platform])} FROZEN — no writes until unfrozen (syncs still run as read-only mirrors)."
    end

    desc "Unfreeze a platform (writes still require an approved window): ops:push_guard:unfreeze[square]"
    task :unfreeze, [:platform] => :environment do |_, args|
      load_tenant!
      PlatformPushGuard.unfreeze!(args[:platform], actor: ENV["ACTOR_EMAIL"].presence || "rake")
      puts "#{PlatformPushGuard.label(args[:platform])} unfrozen — pushes still need an approved window."
    end
  end
end
