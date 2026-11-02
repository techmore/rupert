# frozen_string_literal: true

namespace :square do
  desc 'Read Square Loyalty (program, members, ledger) and report what would be stored; APPLY=1 stores the read-only local copy'
  task loyalty: :environment do
    Current.tenant = Tenant.find(ENV.fetch('TENANT_ID'))
    Current.user = User.find(ENV.fetch('ACTOR_ID'))
    puts SquareLoyaltyImport.new.call(apply: ENV['APPLY'] == '1').to_json
  ensure
    Current.reset
  end

  desc 'Enable or disable the hourly read-only Square Loyalty refresh for a workspace; ENABLED=1 enables it'
  task loyalty_schedule: :environment do
    raise ArgumentError, 'ENABLED must be 1 or 0' unless %w[0 1].include?(ENV['ENABLED'])

    Current.tenant = Tenant.find(ENV.fetch('TENANT_ID'))
    Current.user = User.find(ENV.fetch('ACTOR_ID'))
    SquareLoyaltySync.configure!(enabled: ENV.fetch('ENABLED') == '1')
    puts({ enabled: SquareLoyaltySync.enabled?, schedule: SquareLoyaltySync::INTERVAL }.to_json)
  ensure
    Current.reset
  end
end
