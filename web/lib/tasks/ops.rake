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
      puts "#{PlatformPushGuard.label(args[:platform])} FROZEN — no writes and no syncs until unfrozen."
    end

    desc "Unfreeze a platform (writes still require an approved window): ops:push_guard:unfreeze[square]"
    task :unfreeze, [:platform] => :environment do |_, args|
      load_tenant!
      PlatformPushGuard.unfreeze!(args[:platform], actor: ENV["ACTOR_EMAIL"].presence || "rake")
      puts "#{PlatformPushGuard.label(args[:platform])} unfrozen — pushes still need an approved window."
    end
  end
end
