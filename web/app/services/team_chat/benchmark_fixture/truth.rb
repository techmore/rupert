# frozen_string_literal: true

module TeamChat
  class BenchmarkFixture
    # The gold answers, worked out from the generator's own plain-Ruby bookkeeping (never from the database
    # and never from Rupert's reporting tools), so a benchmark can check Rupert against an independent source.
    # Money is integer cents in the order's own currency; currencies are never added together except in
    # `top_products_mixed`, which mirrors what sales_summary does so that tool can be checked too.
    class Truth
      WEEKDAYS = Date::DAYNAMES
      PAY_WEEK_START_CWDAY = 4 # Thursday, Rupert's default pay-week start.

      # ledger: the generator's plain records (orders, refunds, expenses, sheets, tasks, products, customers).
      def initialize(ledger, today:, seed:, overdue_after_days:, low_stock_threshold:)
        @ledger = ledger
        @today = today
        @seed = seed
        @overdue_after_days = overdue_after_days
        @low_stock_threshold = low_stock_threshold
      end

      def to_h
        {
          'meta' => meta, 'counts' => counts,
          'sales_by_month' => sales_by_month, 'tax_by_month' => tax_by_month,
          'fully_refunded_orders' => fully_refunded_orders,
          'daily_orders_last_14_days' => daily_orders_last_14_days, 'weeks' => weeks,
          'top_products_sept_2026' => top_products(Date.new(2026, 9, 1)..Date.new(2026, 9, 30)),
          'best_weekday_last_quarter' => best_weekday_last_quarter,
          'refunds_by_month' => refunds_by_month,
          'expenses' => expenses, 'timesheets' => timesheets, 'tasks' => tasks,
          'stock' => stock, 'customers' => customers, 'order_queues' => order_queues
        }
      end

      private

      def orders = @ledger[:orders]
      def sales = orders.reject { |order| order[:state] == :placed } # paid, fulfilled or refunded
      def money_row(list) = { 'orders' => list.size, 'gross_cents' => list.sum { |order| order[:gross_cents] } }
      def month_key(date) = date.strftime('%Y-%m')

      def meta
        { 'seed' => @seed, 'today' => @today.iso8601, 'first_order_day' => orders.map { |order| order[:date] }.min.iso8601,
          'basis' => 'Orders counted as sales are paid, fulfilled or later refunded (what the metric tool counts); ' \
                     'sales_summary leaves out orders whose status became refunded (see fully_refunded_orders).' }
      end

      def counts
        { 'orders' => orders.size, 'sales_orders' => sales.size, 'products' => @ledger[:products].size,
          'sources' => sales.map { |order| order[:source] }.uniq.sort, 'currencies' => sales.map { |order| order[:currency] }.uniq.sort,
          'refunds' => @ledger[:refunds].size, 'expenses' => @ledger[:expenses].size, 'employees' => @ledger[:employees].size,
          'timesheets' => @ledger[:sheets].size, 'tasks' => @ledger[:tasks].size, 'customers' => @ledger[:customers].size }
      end

      # month => currency => { orders, gross_cents, tax_cents, by_source }
      def sales_by_month
        group_sorted(sales) { |order| month_key(order[:date]) }.transform_values do |month|
          group_sorted(month) { |order| order[:currency] }.transform_values do |list|
            money_row(list).merge('tax_cents' => list.sum { |order| order[:tax_cents] },
              'by_source' => group_sorted(list) { |order| order[:source] }.transform_values { |rows| money_row(rows) })
          end
        end
      end

      def tax_by_month
        sales_by_month.transform_values { |month| month.transform_values { |row| row['tax_cents'] } }
      end

      def fully_refunded_orders
        sales.select { |order| order[:fully_refunded] }.map do |order|
          { 'order_number' => order[:number], 'month' => month_key(order[:date]), 'source' => order[:source],
            'currency' => order[:currency], 'gross_cents' => order[:gross_cents] }
        end
      end

      def daily_orders_last_14_days
        ((@today - 13)..@today).to_h do |day|
          list = sales.select { |order| order[:date] == day }
          [day.iso8601, { 'weekday' => WEEKDAYS[day.wday], 'orders' => list.size,
                          'gross_cents_by_currency' => totals_by(list, :currency) }]
        end
      end

      # Monday-first weeks, the way "this week" and "last week" read; this week runs to today.
      def weeks
        this_start = @today.beginning_of_week
        { 'this_week' => week_row(this_start, @today), 'last_week' => week_row(this_start - 7, this_start - 1) }
      end

      def week_row(from, to)
        list = sales.select { |order| (from..to).cover?(order[:date]) }
        { 'from' => from.iso8601, 'to' => to.iso8601, 'orders' => list.size, 'gross_cents_by_currency' => totals_by(list, :currency),
          'orders_by_currency' => list.group_by { |order| order[:currency] }.sort.to_h { |currency, rows| [currency, rows.size] } }
      end

      def totals_by(list, key)
        list.group_by { |order| order[key] }.sort.to_h { |name, rows| [name, rows.sum { |order| order[:gross_cents] }] }
      end

      # Revenue is the sum of line totals before any order discount, which is how the order lines record it.
      def top_products(range)
        lines = sales.select { |order| range.cover?(order[:date]) }.flat_map do |order|
          order[:lines].map { |line| line.merge(currency: order[:currency]) }
        end
        by_currency = lines.group_by { |line| line[:currency] }.sort.to_h { |currency, rows| [currency, rank(rows)] }
        by_currency.merge('mixed_currencies_like_sales_summary' => rank(lines))
      end

      def rank(lines)
        lines.group_by { |line| [line[:name], line[:sku]] }.map do |(name, sku), rows|
          { 'name' => name, 'sku' => sku, 'units' => rows.sum { |line| line[:quantity] }, 'revenue_cents' => rows.sum { |line| line[:line_cents] } }
        end.sort_by { |row| [-row['revenue_cents'], row['name']] }.first(5)
      end

      def best_weekday_last_quarter
        last_end = @today.beginning_of_quarter - 1
        range = last_end.beginning_of_quarter..last_end
        list = sales.select { |order| range.cover?(order[:date]) }
        { 'from' => range.first.iso8601, 'to' => range.last.iso8601 }.merge(
          list.group_by { |order| order[:currency] }.sort.to_h { |currency, rows| [currency, weekday_row(rows)] }
        )
      end

      def weekday_row(list)
        totals = list.group_by { |order| order[:date].wday }.transform_values { |rows| rows.sum { |order| order[:gross_cents] } }
        ranked = totals.sort_by { |wday, cents| [-cents, wday] }
        { 'best' => WEEKDAYS[ranked[0][0]], 'best_gross_cents' => ranked[0][1], 'runner_up' => WEEKDAYS[ranked[1][0]],
          'runner_up_gross_cents' => ranked[1][1], 'gross_cents_by_weekday' => ranked.to_h { |wday, cents| [WEEKDAYS[wday], cents] } }
      end

      # month => source => currency => { count, amount_cents }, counted by the day the refund was made.
      def refunds_by_month
        group_sorted(@ledger[:refunds]) { |refund| month_key(refund[:date]) }.transform_values do |month|
          group_sorted(month) { |refund| refund[:source] }.transform_values do |rows|
            group_sorted(rows) { |refund| refund[:currency] }.transform_values do |list|
              { 'count' => list.size, 'amount_cents' => list.sum { |refund| refund[:amount_cents] } }
            end
          end
        end
      end

      def expenses
        list = @ledger[:expenses]
        { 'currency' => 'USD', 'total_cents' => list.sum { |row| row[:amount_cents] }, 'count' => list.size,
          'by_category' => group_sorted(list) { |row| row[:category] }.transform_values { |rows| rows.sum { |row| row[:amount_cents] } },
          'by_month' => group_sorted(list) { |row| month_key(row[:date]) }.transform_values { |rows| rows.sum { |row| row[:amount_cents] } } }
      end

      def last_pay_week
        current_start = @today - ((@today.cwday - PAY_WEEK_START_CWDAY) % 7)
        (current_start - 7)..(current_start - 1)
      end

      def timesheets
        week = last_pay_week
        awaiting = @ledger[:sheets].select { |sheet| sheet[:status] == 'submitted' }
        overdue = awaiting.select { |sheet| sheet[:submitted_on] <= @today - @overdue_after_days }
        { 'last_pay_week' => { 'from' => week.first.iso8601, 'to' => week.last.iso8601, 'hours_by_employee' => hours_in(week) },
          'awaiting_approval' => awaiting.size, 'awaiting_approval_list' => sheet_labels(awaiting),
          'overdue_approval_days' => @overdue_after_days, 'overdue_approvals' => sheet_labels(overdue),
          'drafts' => @ledger[:sheets].select { |sheet| sheet[:status] == 'draft' }.map { |sheet| "#{sheet[:employee]} (#{sheet[:from].iso8601} to #{sheet[:to].iso8601})" } }
      end

      def hours_in(range)
        @ledger[:employees].to_h do |employee|
          hours = @ledger[:sheets].select { |sheet| sheet[:employee] == employee[:name] }.flat_map { |sheet| sheet[:entries] }
            .select { |entry| range.cover?(entry[:date]) }.sum { |entry| entry[:hours] }
          [employee[:name], hours.to_f]
        end
      end

      def sheet_labels(list)
        list.map { |sheet| "#{sheet[:employee]} (#{sheet[:from].iso8601} to #{sheet[:to].iso8601}, submitted #{sheet[:submitted_on].iso8601})" }.sort
      end

      def tasks
        open_tasks = @ledger[:tasks].reject { |task| task[:status] == 'done' }
        overdue = open_tasks.select { |task| task[:due_on] < @today }.sort_by { |task| [task[:due_on], task[:title]] }
        friday = @today + ((5 - @today.cwday) % 7)
        { 'total' => @ledger[:tasks].size, 'open' => open_tasks.size,
          'overdue_titles' => overdue.map { |task| task[:title] },
          'overdue' => overdue.map { |task| { 'title' => task[:title], 'due_on' => task[:due_on].iso8601, 'days_overdue' => (@today - task[:due_on]).to_i } },
          'due_this_friday' => open_tasks.select { |task| task[:due_on] == friday }.map { |task| task[:title] },
          'about_low_stock_products' => @ledger[:tasks].select { |task| task[:product] }.map { |task| task[:title] } }
      end

      def stock
        low = @ledger[:products].select { |product| product[:stock] <= @low_stock_threshold }.sort_by { |product| [product[:stock], product[:name]] }
        { 'low_stock_threshold' => @low_stock_threshold,
          'low_stock_products' => low.map { |product| product[:name] },
          'out_of_stock_products' => low.select { |product| product[:stock].zero? }.map { |product| product[:name] },
          'open_alert_skus' => low.map { |product| product[:sku] }.sort }
      end

      def customers
        @ledger[:customers].to_h do |customer|
          list = sales.select { |order| order[:customer] == customer[:name] }
          [customer[:name], { 'orders' => list.size, 'gross_cents_by_currency' => totals_by(list, :currency) }]
        end
      end

      def order_queues
        unpaid = orders.select { |order| order[:state] == :placed }
        unshipped = orders.select { |order| order[:state] == :paid && order[:source] == 'shopify' }
        { 'unpaid_orders' => unpaid.map { |order| order[:number] }, 'paid_unshipped_orders' => unshipped.map { |order| order[:number] } }
      end

      def group_sorted(list, &) = list.group_by(&).sort.to_h
    end
  end
end
