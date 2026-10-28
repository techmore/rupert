# frozen_string_literal: true

minutes = Integer(ENV.fetch('MAX_AGE_MIN', '45'))
raise ArgumentError, 'MAX_AGE_MIN must be positive' unless minutes.positive?
failures = SyncWatch.failures(max_age: minutes.minutes)
if failures.empty?
  puts 'ok: configured catalog syncs are fresh'
else
  failures.each do |failure|
    warn "STALE: tenant #{failure[:tenant_id]}, #{failure[:source]}: last successful acquisition #{failure[:last_success] || 'unknown'}#{" (#{failure[:state]})" if failure[:state]}"
  end
  exit 1
end
