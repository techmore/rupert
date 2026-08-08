# frozen_string_literal: true

namespace :ops do
  desc "Run a full Shopify + Square sync"
  task sync: :environment do
    SyncEngine.run!(mode: "manual", actor: "rake")
    puts "Sync completed"
  end

  desc "Run a single-source sync: ops:sync_source[shopify|square]"
  task :sync_source, [:source] => :environment do |_, args|
    SyncEngine.run_source!(args[:source], actor: "rake")
    puts "#{args[:source]} sync completed"
  end

  desc "Print the reconciliation plan summary"
  task reconcile: :environment do
    rows = Reconciler.build_rows
    puts Reconciler.summary(rows).to_json
  end
end
