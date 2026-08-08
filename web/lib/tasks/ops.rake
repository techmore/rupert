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

  desc "Run a single-source sync: ops:sync_source[shopify|square]"
  task :sync_source, [:source] => :environment do |_, args|
    load_tenant!
    SyncEngine.run_source!(args[:source], actor: "rake")
    puts "#{args[:source]} sync completed"
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
end
