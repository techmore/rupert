# frozen_string_literal: true

# Fast, reusable sales reporting against the Rupert DB.
# Run via Rails so models/EnvStore/DB config are already wired:
#
#   bin/rails runner scripts/sales_report.rb 2026-08-08 2026-08-09 [FLAGS]
#
# Flags (combinable):
#   --mobile        restrict to the mobile "Vendor Events" Square location
#   --by-day        include a per-day line
#   --items N       top line items by revenue (default 10)
#   --orders N      top orders by revenue (default 8)
#   --source X      restrict to a source: square | shopify
#   --channel X     restrict to a channel: pos | online
#
# With no date args, defaults to the most recent weekend (Sat-Sun).
# With one date arg, reports that single day.

# Locate the mobile Square location once (kind == "MOBILE").
def mobile_location_id
  @mobile_location_id ||= ActiveRecord::Base.connection
                                            .execute("select \"externalId\" from \"Location\" where source='square' and kind='MOBILE' order by \"syncedAt\" limit 1")
                                            .first&.fetch('externalId')
end

def money(cents)
  format('$%.2f', (cents || 0) / 100.0)
end

def parse_day(str)
  Date.parse(str)
rescue ArgumentError
  warn "bad date: #{str}"
  exit 1
end

def take(args, key)
  i = args.index { |a| a == key || a.start_with?("#{key}=") }
  return nil if i.nil?

  if args[i].start_with?("#{key}=")
    val = args[i].split('=', 2)[1]
    args.slice!(i)
  else
    val = args[i + 1]
    args.slice!(i, 2)
  end
  val
end

args = ARGV.dup
days = args.select { |a| a.match?(/\A\d{4}-\d{2}-\d{2}\z/) }
args -= days

mobile = args.include?('--mobile')
by_day = args.include?('--by-day')
items_n = (take(args, '--items') || 10).to_i
orders_n = (take(args, '--orders') || 8).to_i
source = take(args, '--source')
channel = take(args, '--channel')

if days.empty?
  today = Date.current
  sat = today.beginning_of_week - 2 # week starts Mon; Sat is Mon+5
  start_d = sat
  end_d = sat + 1
  day_label = "recent weekend (#{start_d} - #{end_d})"
else
  start_d = parse_day(days[0])
  end_d = days[1] ? parse_day(days[1]) : start_d
  day_label = end_d == start_d ? start_d.to_s : "#{start_d} - #{end_d}"
end

loc = mobile ? mobile_location_id : nil
if mobile && loc.nil?
  warn 'no MOBILE Square location found'
  exit 1
end

conn = ActiveRecord::Base.connection
start_ts = "#{start_d}T00:00:00"
end_ts = "#{end_d + 1}T00:00:00"

filters = +"occurred_at >= '#{start_ts}' and occurred_at < '#{end_ts}'"
filters << " and location_id = '#{loc}'" if loc
filters << " and source = '#{source}'" if source
filters << " and channel = '#{channel}'" if channel
scope2 = "join orders o on o.id = ol.order_id where #{filters}"

puts "== Sales report: #{day_label}#{mobile ? ' (MOBILE location)' : ''} =="

# Totals by day/source/channel
puts "\n-- Totals --"
rows = conn.execute("select source, channel, count(*) n, sum(gross_cents) rev from orders where #{filters} group by source, channel order by rev desc").to_a
grand_n = 0
grand_rev = 0
rows.each do |r|
  grand_n += r['n']
  grand_rev += r['rev']
  puts "  #{r['source']}/#{r['channel']}: #{r['n']} orders / #{money(r['rev'])}"
end
puts "  TOTAL: #{grand_n} orders / #{money(grand_rev)}"

puts "\n-- By day --" if by_day
if by_day
  conn.execute("select date(occurred_at at time zone 'UTC') d, count(*) n, sum(gross_cents) rev from orders where #{filters} group by 1 order by 1").to_a.each do |r|
    puts "  #{r['d']}: #{r['n']} / #{money(r['rev'])}"
  end
end

puts "\n-- Top orders --"
conn.execute("select order_number, occurred_at, gross_cents rev from orders where #{filters} order by gross_cents desc limit #{orders_n}").to_a.each do |r|
  puts "  #{money(r['rev'])} - #{r['order_number']} (#{r['occurred_at'].strftime('%Y-%m-%d %H:%M')})"
end

puts "\n-- Top items --"
conn.execute("select ol.name, sum(ol.quantity) q, sum(ol.line_cents) rev from order_lines ol #{scope2} group by ol.name order by rev desc limit #{items_n}").to_a.each do |r|
  puts "  #{r['name']} (#{r['q']}) - #{money(r['rev'])}"
end
