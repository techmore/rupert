# frozen_string_literal: true

module Mcp
  module Tools
    # "What did we order last week?", "is the bottle order late?", "what's the
    # total on PO 1042?", "how much did we spend with our top vendor?", "how long
    # does the packaging vendor take?" Purchase orders and vendors, read-only.
    class PurchaseOrders < Tool
      VIEWS = %w[orders vendors].freeze
      STATUSES = %w[open draft ordered received cancelled all].freeze
      PLACED = %w[ordered received].freeze
      CURRENCY = 'USD'
      MAX_ORDERS = 5000
      LINES_WHEN_AT_MOST = 5

      tool 'purchase_orders',
        title: 'Purchase orders and vendors',
        description: 'Purchase orders (POs) and vendors: open, late and received POs with totals and lines, and the vendor list ' \
                     'with spend, open orders and lead time. view orders (default): each PO with vendor, status ' \
                     '(draft, ordered = waiting for delivery, received, cancelled), created, ordered, expected and received dates, ' \
                     'deliveries, line count, units ordered vs received, total / received / still-due amounts, overdue and ' \
                     'partial-delivery flags; lines (item, SKU, ordered, received, short, unit cost) come with a PO number ' \
                     'search, a short list, or include_lines. Filter by status, vendor, PO number / item / SKU text, ordered ' \
                     'date range, overdue_only. view vendors: every vendor with contact name, payment terms, open and overdue ' \
                     'POs, spend on POs placed in the date range, last order date, average lead time in days from ordered to ' \
                     'received and on-time rate. Answers "open POs", "what did we order last week", "is the tea order late", ' \
                     '"total on PO 1042", "ordered vs received", "spend with each vendor this quarter", "vendor lead times", ' \
                     '"list all vendors". Amounts are integer cents plus dollars. Not here: vendor email, phone or address, ' \
                     'invoices or bills matched to POs, and stock movements (use stock_movements). Read-only.',
        scope: 'purchasing:read'

      input_schema(
        type: 'object',
        properties: {
          view: { type: 'string', enum: VIEWS, description: 'orders (default) or vendors.' },
          status: { type: 'string', enum: STATUSES, description: 'orders view. open = ordered and not yet fully received. Default all.' },
          vendor: { type: 'string', maxLength: 80, description: 'Part of the vendor name.' },
          query: { type: 'string', maxLength: 80, description: 'orders view: PO number, item name or SKU fragment, e.g. "1042" or "dropper".' },
          from: DATE_PROPERTY.merge(description: 'First ordered day (inclusive). orders: no date filter unless given. vendors: spend window, default 365 days ago.'),
          to: DATE_PROPERTY.merge(description: 'Last ordered day (inclusive). Default today.'),
          overdue_only: { type: 'boolean', description: 'orders view: only POs past their expected date and not received.' },
          include_lines: { type: 'boolean', description: 'orders view: include every PO\'s lines. Lines are always included for 5 or fewer POs.' },
          **PAGE_PROPERTIES
        },
        additionalProperties: false
      )

      def call(args)
        args['view'] == 'vendors' ? vendors(args) : orders(args)
      end

      private

      # ---- orders ----

      def orders(args)
        records = load_orders(args)
        dated = args['from'].present? || args['to'].present?
        if dated
          from, to = date_range(args, default_from: Date.current - 365)
          records = records.select { |order| order[:ordered_on].between?(from, to) }
        end
        records = records.select { |order| order[:overdue] } if args['overdue_only']
        records = records.sort_by { |order| [-order[:ordered_on].jd, -order[:id]] }
        page, meta = paginate(records, args)
        lines = args['include_lines'] || records.size <= LINES_WHEN_AT_MOST || args['query'].present?
        rows = page.map { |order| order_row(order, lines: lines) }
        data = { view: 'orders', currency: CURRENCY, from: (from.iso8601 if dated), to: (to.iso8601 if dated),
                 counts_by_status: records.group_by { |order| order[:record].status }.transform_values(&:size),
                 overdue: records.count { |order| order[:overdue] }, partial: records.count { |order| order[:partial] },
                 totals: [money_totals(records)], rows: rows, meta: meta,
                 note: 'Purchase orders carry no currency of their own; amounts are in the shop currency (USD). ' \
                       'Ordered date is when the PO was placed (its creation date if that was not logged).' }.compact
        result(order_summary(data, rows), data)
      end

      def load_orders(args)
        scope = Purchasing::PurchaseOrder.where(tenant_id: tenant.id).includes(:vendor, :lines, :deliveries)
        scope = filter_status(scope, args['status'])
        scope = scope.joins(:vendor).where("vendors.name LIKE ? ESCAPE '!'", like(args['vendor'])) if args['vendor'].present?
        if args['query'].present?
          lines = Purchasing::PurchaseOrderLine.where("name LIKE :q ESCAPE '!' OR sku LIKE :q ESCAPE '!'", q: like(args['query'])).select(:purchase_order_id)
          scope = scope.where("purchase_orders.order_number LIKE ? ESCAPE '!' OR purchase_orders.id IN (?)", like(args['query']), lines)
        end
        orders = scope.order(created_at: :desc).limit(MAX_ORDERS).to_a
        placed = placed_dates(orders.map(&:id))
        orders.map { |order| facts(order, placed[order.id.to_s]) }
      end

      def filter_status(scope, status)
        case status
        when nil, '', 'all' then scope
        when 'open' then scope.where(status: 'ordered')
        else scope.where(status: status)
        end
      end

      # When each PO was placed, from the audit trail (po_placed). Older rows fall back to the creation date.
      def placed_dates(ids)
        return {} if ids.empty?

        ::ActivityLog.where(tenant_id: tenant.id, action: 'po_placed', subject_type: 'Purchasing::PurchaseOrder', subject_id: ids.map(&:to_s))
          .group(:subject_id).minimum(:created_at)
      end

      def facts(order, placed_at)
        lines = order.lines.to_a
        deliveries = order.deliveries.sort_by(&:created_at)
        ordered_on = (placed_at || order.created_at).in_time_zone.to_date
        received_on = order.received_date || (deliveries.last&.created_at&.in_time_zone&.to_date if order.status == 'received')
        total = lines.sum(&:line_cents)
        received = lines.sum { |line| line.received_quantity * line.unit_cost_cents }
        overdue = order.status == 'ordered' && order.expected_date.present? && order.expected_date < Date.current
        partial = order.status == 'ordered' && lines.any? { |line| line.received_quantity.positive? }
        { id: order.id, record: order, lines: lines, deliveries: deliveries, ordered_on: ordered_on, placed_logged: placed_at.present?,
          received_on: received_on, total: total, received: received, overdue: overdue, partial: partial }
      end

      def order_row(order, lines:)
        record = order[:record]
        row = {
          id: record.id, order_number: record.order_number, vendor: record.vendor&.name, vendor_id: record.vendor_id, status: record.status,
          created_on: record.created_at.in_time_zone.to_date.iso8601, ordered_on: order[:ordered_on].iso8601,
          expected_date: record.expected_date&.iso8601, received_on: order[:received_on]&.iso8601,
          first_delivery_on: order[:deliveries].first&.created_at&.in_time_zone&.to_date&.iso8601, deliveries: order[:deliveries].size,
          lead_days: lead_days(order), line_count: order[:lines].size,
          units_ordered: order[:lines].sum(&:quantity), units_received: order[:lines].sum(&:received_quantity),
          currency: CURRENCY, total_cents: order[:total], total_dollars: money(order[:total]),
          received_cents: order[:received], received_dollars: money(order[:received]),
          due_cents: order[:total] - order[:received], due_dollars: money(order[:total] - order[:received]),
          overdue: order[:overdue], days_overdue: order[:overdue] ? (Date.current - record.expected_date).to_i : nil,
          partial_delivery: order[:partial], notes: ActivityLog.scrub(record.notes, max: 200).presence,
          path: Rails.application.routes.url_helpers.purchasing_purchase_order_path(record)
        }
        row[:lines] = order[:lines].map { |line| line_row(line) } if lines
        row.compact
      end

      def line_row(line)
        { name: line.name, sku: line.sku, quantity: line.quantity, received_quantity: line.received_quantity,
          short: line.quantity - line.received_quantity, unit_cost_cents: line.unit_cost_cents, unit_cost_dollars: money(line.unit_cost_cents),
          line_cents: line.line_cents, line_dollars: money(line.line_cents) }
      end

      def lead_days(order)
        return unless order[:received_on] && order[:record].status == 'received'

        (order[:received_on] - order[:ordered_on]).to_i
      end

      def money_totals(records)
        placed = records.select { |order| PLACED.include?(order[:record].status) }
        total = placed.sum { |order| order[:total] }
        received = placed.sum { |order| order[:received] }
        due = records.select { |order| order[:record].status == 'ordered' }.sum { |order| order[:total] - order[:received] }
        { currency: CURRENCY, placed_orders: placed.size, placed_total_cents: total, placed_total_dollars: money(total),
          received_cents: received, received_dollars: money(received), open_due_cents: due, open_due_dollars: money(due) }
      end

      def order_summary(data, rows)
        totals = data[:totals].first
        window = data[:from] ? " ordered #{data[:from]} to #{data[:to]}" : ''
        head = "#{data[:meta][:total]} purchase orders#{window}: " +
               data[:counts_by_status].map { |status, count| "#{count} #{status}" }.join(', ').presence.to_s +
               "; #{data[:overdue]} overdue. Placed total #{totals[:placed_total_dollars]} #{CURRENCY}, still due #{totals[:open_due_dollars]}."
        return head if rows.empty?

        list = rows.first(6).map do |row|
          "#{row[:order_number]} #{row[:vendor]} #{row[:status]} #{row[:total_dollars]}" \
            "#{row[:overdue] ? " (#{row[:days_overdue]}d late)" : (row[:expected_date] && row[:status] == 'ordered' ? " due #{row[:expected_date]}" : '')}"
        end
        "#{head} #{list.join('; ')}".first(600)
      end

      # ---- vendors ----

      def vendors(args)
        from, to = date_range(args, default_from: Date.current - 365)
        scope = Purchasing::Vendor.where(tenant_id: tenant.id).ordered
        scope = scope.where("name LIKE ? ESCAPE '!'", like(args['vendor'])) if args['vendor'].present?
        vendors = scope.to_a
        by_vendor = load_orders({ 'status' => 'all' }).group_by { |order| order[:record].vendor_id }
        paid = vendor_payments(vendors.map(&:id), from, to)
        rows = vendors.map { |vendor| vendor_row(vendor, by_vendor.fetch(vendor.id, []), from, to, paid) }
        rows = rows.sort_by { |row| [-row[:spend_cents], row[:name].to_s.downcase] }
        page, meta = paginate(rows, args)
        data = { view: 'vendors', currency: CURRENCY, from: from.iso8601, to: to.iso8601, vendors: rows.size,
                 spend_total_cents: rows.sum { |row| row[:spend_cents] }, rows: page, meta: meta,
                 note: 'Spend is the value of purchase orders placed in the window (ordered or received), not payments. ' \
                       'Lead time is ordered date to received date over every fully received PO. Vendor email, phone and address are not shown.' }
        data[:spend_total_dollars] = money(data[:spend_total_cents])
        data[:payments_note] = 'Payments to vendors need finance access.' if paid.nil?
        result(vendor_summary(data), data)
      end

      def vendor_row(vendor, orders, from, to, paid)
        window = orders.select { |order| PLACED.include?(order[:record].status) && order[:ordered_on].between?(from, to) }
        spend = window.sum { |order| order[:total] }
        received = orders.select { |order| order[:record].status == 'received' && lead_days(order) }
        leads = received.map { |order| lead_days(order) }
        timed = received.select { |order| order[:record].expected_date }
        on_time = timed.count { |order| order[:received_on] <= order[:record].expected_date }
        open = orders.select { |order| order[:record].status == 'ordered' }
        row = {
          id: vendor.id, name: vendor.name, contact_name: vendor.contact_name.presence, payment_terms: vendor.payment_terms,
          purchase_orders: orders.size, open_orders: open.size, overdue_orders: open.count { |order| order[:overdue] },
          open_due_cents: open.sum { |order| order[:total] - order[:received] },
          orders_in_window: window.size, spend_cents: spend, spend_dollars: money(spend),
          last_ordered_on: orders.map { |order| order[:ordered_on] }.max&.iso8601,
          average_lead_days: leads.any? ? (leads.sum.to_f / leads.size).round(1) : nil, lead_time_orders: leads.size,
          on_time_percent: timed.any? ? (100.0 * on_time / timed.size).round : nil,
          path: Rails.application.routes.url_helpers.purchasing_vendor_path(vendor)
        }
        row[:open_due_dollars] = money(row[:open_due_cents])
        if paid
          row[:paid_in_window_cents] = paid.fetch(vendor.id, 0)
          row[:paid_in_window_dollars] = money(row[:paid_in_window_cents])
        end
        row.compact
      end

      # Payments recorded in bookkeeping, only for people who may see finance.
      def vendor_payments(ids, from, to)
        return unless token.allows?('finance:read')

        Finance::VendorPayment.where(tenant_id: tenant.id, vendor_id: ids, paid_on: from..to).group(:vendor_id).sum(:amount_cents)
      end

      def vendor_summary(data)
        head = "#{data[:vendors]} vendors. PO spend #{data[:from]} to #{data[:to]}: #{data[:spend_total_dollars]} #{CURRENCY}."
        top = data[:rows].first(6).map do |row|
          lead = row[:average_lead_days] ? ", lead #{row[:average_lead_days]}d" : ''
          "#{row[:name]} #{row[:spend_dollars]} (#{row[:open_orders]} open#{lead})"
        end
        top.any? ? "#{head} #{top.join('; ')}".first(600) : head
      end

      def like(text) = "%#{Purchasing::PurchaseOrder.sanitize_sql_like(text.to_s.strip, '!')}%"
    end
  end
end
