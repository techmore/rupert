# frozen_string_literal: true

# Synthetic, deterministic retail facts for an isolated test database.
# Usage: RAILS_ENV=test RUPERT_SQLITE_DATABASE_TEST=/private/fixture.sqlite3
#        bin/rails db:prepare db:fixtures:load
#        bin/rails runner script/team_chat_benchmark_fixture.rb
abort 'This fixture may run only in a separately named test database.' unless Rails.env.test? && ENV['RUPERT_SQLITE_DATABASE_TEST'].to_s.include?('benchmark')

Current.tenant = Tenant.find('test-tenant-default')
Current.user = User.find_by!(email: 'admin@example.com', tenant_id: Current.tenant.id)
abort 'Fixture already contains orders; refusing to change it.' if Core::Order.exists?

anchor = Date.iso8601(ENV.fetch('BENCHMARK_DATE'))
[
  [anchor - 1, 10_000, 'shopify', 'USD', 'Tea'],
  [anchor - 1, 5_000, 'square', 'USD', 'Mints'],
  [anchor - 1, 9_999, 'shopify', 'CAD', 'Tea'],
  [anchor - 2, 6_000, 'shopify', 'USD', 'Tea'],
  [anchor - 8, 4_000, 'rupert_pos', 'USD', 'Mints'],
  [anchor - 35, 8_000, 'square', 'USD', 'Tea']
].each_with_index do |(day, cents, source, currency, item), index|
  order = Core::Order.create!(source: source, source_order_id: "benchmark-fixture-#{index}",
    occurred_at: day.in_time_zone.change(hour: 12), gross_cents: cents, tax_cents: 0, currency: currency)
  order.mark_paid!
  order.order_lines.create!(name: item, sku: item.downcase, unit_cents: cents, quantity: 1, line_cents: cents)
end
puts "Synthetic benchmark fixture created for #{anchor.iso8601}: #{Core::Order.count} paid orders."
