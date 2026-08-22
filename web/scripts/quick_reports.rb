# frozen_string_literal: true

# Quick reporting shortcuts for the Buzz agent (@rupert). Each command answers
# a question teammates ask in chat. Output is compact, plain-text, and safe to
# paste into a message.
#
# Usage:
#   bin/rails runner scripts/quick_reports.rb <command> [args...]
#
# Commands:
#   sales [from] [to]   revenue by source/channel for a window (default: last 7 days)
#   today               today's revenue/orders vs yesterday, top orders
#   top_products [n]    top n line items by revenue (default 5, last 7 days)
#   top_orders [n]      top n orders by revenue (default 5, last 7 days)
#   tenders [from] [to] payment method mix for a window (default: last 7 days)
#   inventory           tracked variants, low/out/negative, top open stock alerts
#   reconcile           reconcile summary + biggest Shopify-Square drift
#   sync                sync health: recent runs, status, freshness
#   customers [n]       top n customers by lifetime revenue
#   help                this help

def tenant
  @tenant ||= Tenant.where(status: 'active').first || Tenant.first
end

def require_tenant!
  if tenant.nil?
    warn('no tenant configured')
    exit(1)
  end

  Current.tenant = tenant
end

def money_cents(cents)
  format('$%.2f', (cents || 0) / 100.0)
end

def money_dollars(dollars)
  format('$%.2f', dollars || 0)
end

def parse_day(value, default = nil)
  return default if value.nil? || value.empty?

  Date.parse(value)
rescue ArgumentError
  warn("bad date: #{value}")
  exit(1)
end

def window(args)
  from = parse_day(args[0], Time.current.to_date - 6.days).beginning_of_day
  to = (parse_day(args[1], Time.current.to_date) + 1.day).beginning_of_day
  [from, to]
end

def orders_between(from, to)
  Core::Order.where('occurred_at >= ? AND occurred_at < ?', from, to)
end

def cmd_sales(args)
  from, to = window(args)
  scope = orders_between(from, to)
  total_cents = scope.sum(:gross_cents)
  count = scope.count
  puts "Sales #{from.to_date.iso8601}..#{(to - 1.day).to_date.iso8601}: #{money_cents(total_cents)} / #{count} orders"
  scope.group(:source).order('1').count.each do |s, n|
    puts "  #{s}: #{money_cents(scope.where(source: s).sum(:gross_cents))} (#{n} orders)"
  end
  scope.group(:channel).order('1').count.each do |c, n|
    puts "  channel #{c}: #{money_cents(scope.where(channel: c).sum(:gross_cents))} (#{n} orders)"
  end
  (from.to_date..(to - 1.day).to_date).each do |d|
    day = orders_between(d.beginning_of_day, d.end_of_day)
    next if day.count.zero?

    puts "  #{d.iso8601}: #{money_cents(day.sum(:gross_cents))} (#{day.count})"
  end
end

def cmd_today(_args)
  d = Time.current.to_date
  today = orders_between(d.beginning_of_day, d.end_of_day)
  yesterday = orders_between((d - 1).beginning_of_day, (d - 1).end_of_day)
  today_cents = today.sum(:gross_cents)
  y_cents = yesterday.sum(:gross_cents)
  delta = y_cents.zero? ? 'n/a' : "#{((today_cents - y_cents).to_f / y_cents * 100).round}% vs yesterday"
  puts "Today (#{d.iso8601}): #{money_cents(today_cents)} / #{today.count} orders (#{delta})"
  today.order(gross_cents: :desc).limit(5).each do |o|
    puts "  #{money_cents(o.gross_cents)} #{o.display_number} #{o.channel} #{o.occurred_at.strftime('%H:%M')}"
  end
end

def cmd_top_products(args)
  n = (args[0] || '5').to_i
  from, to = window(args.drop(1))
  rows = Core::OrderLine.joins(:order).where('orders.occurred_at >= ? AND orders.occurred_at < ?', from, to)
                        .group(:name).sum(:line_cents).sort_by { |_, c| -c }.first(n)
  puts "Top #{n} products (#{from.to_date.iso8601}..#{(to - 1.day).to_date.iso8601}):"
  rows.each { |name, cents| puts "  #{money_cents(cents)}  #{name}" }
end

def cmd_top_orders(args)
  n = (args[0] || '5').to_i
  from, to = window(args.drop(1))
  puts "Top #{n} orders (#{from.to_date.iso8601}..#{(to - 1.day).to_date.iso8601}):"
  orders_between(from, to).order(gross_cents: :desc).limit(n).each do |o|
    puts "  #{money_cents(o.gross_cents)}  #{o.display_number}  #{o.source}/#{o.channel}  #{o.occurred_at.strftime('%Y-%m-%d %H:%M')}"
  end
end

def cmd_tenders(args)
  from, to = window(args)
  payments = Core::Payment.joins(:order)
                          .where('orders.occurred_at >= ? AND orders.occurred_at < ?', from, to)
                          .where(status: 'completed')
  total_cents = payments.sum(:amount_cents)
  puts "Tenders #{from.to_date.iso8601}..#{(to - 1.day).to_date.iso8601}: #{money_cents(total_cents)}"
  payments.group(:method).sum(:amount_cents).sort_by { |_, c| -c }.each do |method, cents|
    pct = total_cents.zero? ? 0 : (cents.to_f / total_cents * 100).round
    puts "  #{method}: #{money_cents(cents)} (#{pct}%)"
  end
end

def cmd_inventory(_args)
  tracked = ShopifyVariant.where(tracked: true)
  out = tracked.where('"inventoryQuantity" <= 0').count
  low = tracked.where('"inventoryQuantity" > 0 AND "inventoryQuantity" <= 5').count
  neg = tracked.where('"inventoryQuantity" < 0').count
  square_neg = InventoryLevel.where(source: 'square').where('quantity < 0').count
  puts "Inventory: #{tracked.count} tracked variants; #{out} out of stock, #{low} low (<=5), #{neg} with negative Shopify qty"
  puts "  #{square_neg} Square inventory levels negative"
  alerts = StockAlert.where(status: 'open').order(quantity: :asc).limit(5)
  return puts('  no open stock alerts') if alerts.empty?

  puts '  worst alerts:'
  alerts.each { |a| puts "    #{a.sku} qty #{a.quantity} (threshold #{a.threshold})" }
end

def cmd_reconcile(_args)
  rows = Reconciler.build_rows
  s = Reconciler.summary(rows)
  puts "Reconcile: #{s[:actionable]} actionable of #{s[:total]} linked tracked SKUs (drift #{s[:drift_count]}), #{s[:blocked_adjustments]} blocked by negative Square home count"
  return puts('  nothing actionable') if s[:actionable].zero?

  Reconciler.actionable_rows(rows).sort_by { |r| -r.drift.to_i.abs }.first(5).each do |r|
    puts "  #{r.sku} shopify=#{r.shopify_qty} square=#{r.square_qty} drift=#{r.drift > 0 ? '+' : ''}#{r.drift}  #{r.product[0,
                                                                                                                            48]}"
  end
end

def cmd_sync(_args)
  runs = SyncRun.order(startedAt: :desc).limit(10)
  last = runs.first
  puts "Sync: last run #{last&.startedAt&.iso8601} = #{last&.status}#{last&.error ? " (#{last.error[0, 60]})" : ''}"
  ok = runs.count { |r| r.status == 'success' }
  puts "  last 10: #{ok} success / #{runs.count - ok} failed"
  puts "  all time: #{SyncRun.where(status: 'success').count} success / #{SyncRun.where(status: 'failed').count} failed"
end

def cmd_customers(args)
  n = (args[0] || '5').to_i
  rows = Core::Order.where.not(customer_id: nil).group(:customer_id).sum(:gross_cents).sort_by { |_, c| -c }.first(n)
  puts "Top #{n} customers by lifetime revenue:"
  rows.each do |cid, cents|
    customer = Core::Customer.find_by(id: cid)
    label = customer&.name
    label = "#{label} (#{customer.orders.count} orders)" if label && label != 'Unnamed customer'
    label ||= "customer ##{cid}"
    puts "  #{money_cents(cents)}  #{label}"
  end
end

def cmd_help(_args)
  puts <<~HELP
    Quick reports — bin/rails runner scripts/quick_reports.rb <command> [args]
      sales [from] [to]        revenue by source/channel (default last 7 days)
      today                    today's revenue/orders vs yesterday
      top_products [n]         top n line items (default 5)
      top_orders [n]           top n orders (default 5)
      tenders [from] [to]      payment method mix (default last 7 days)
      inventory                tracked variants, low/out/negative, alerts
      reconcile                reconcile summary + biggest drift
      sync                     sync health
      customers [n]            top n customers by revenue
  HELP
end

COMMANDS = {
  'sales' => :cmd_sales,
  'today' => :cmd_today,
  'top_products' => :cmd_top_products,
  'top_orders' => :cmd_top_orders,
  'tenders' => :cmd_tenders,
  'inventory' => :cmd_inventory,
  'reconcile' => :cmd_reconcile,
  'sync' => :cmd_sync,
  'customers' => :cmd_customers,
  'help' => :cmd_help
}.freeze

require_tenant!
command = ARGV.shift || 'help'
method_name = COMMANDS[command.to_s]
if method_name.nil?
  warn("unknown command: #{command}. Try 'help'.")
  exit(1)
end

send(method_name, ARGV)
