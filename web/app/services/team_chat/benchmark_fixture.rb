# frozen_string_literal: true

require 'json'

module TeamChat
  # Builds a rich, reproducible SYNTHETIC business for one test tenant so the team-chat benchmark has
  # non-degenerate questions ("top 5 products", "overdue tasks", "timesheets awaiting approval"...).
  #
  # Everything random comes from Random.new(seed) and every date is relative to the `today:` argument, so two
  # runs give the same data and the same `truth`. The truth is worked out from this class's own bookkeeping
  # (@ledger), never by asking Rupert's reporting tools, so those tools can be checked against it.
  #
  #   fixture = TeamChat::BenchmarkFixture.call(tenant: tenant)
  #   fixture.truth                      # gold answers (Hash)
  #   fixture.truth_json('/tmp/gold.json')
  class BenchmarkFixture
    class Refused < StandardError; end
    class AlreadyLoaded < StandardError; end

    DEFAULT_SEED = 20_261_027
    DEFAULT_TODAY = Date.new(2026, 10, 27)
    FIRST_DAY = Date.new(2026, 7, 1)
    ALLOW_ENV = 'RUPERT_ALLOW_BENCHMARK_FIXTURE'
    MARKER = 'bf-' # every generated order id starts with this, which is how a second run is noticed
    OVERDUE_AFTER_DAYS = 7
    LOW_STOCK_THRESHOLD = 5

    # [name, sku, price in cents, stock]. Earlier rows sell better (see #pick_product).
    PRODUCTS = [
      ['Golden Monkey Black Tea', 'TEA-001', 1850, 64], ['Jasmine Pearls', 'TEA-002', 2400, 0], ['Earl Grey Reserve', 'TEA-003', 1600, 4],
      ['Sencha Green Tea', 'TEA-004', 1700, 41], ['Matcha Ceremonial 30g', 'TEA-005', 3200, 18], ['Chai Spice Blend', 'TEA-006', 1400, 5],
      ['Rooibos Vanilla', 'TEA-007', 1300, 52], ['Peppermint Leaf', 'TEA-008', 1100, 77], ['Ginger Lemon Tea', 'TEA-009', 1250, 2],
      ['Oolong Milk Tea', 'TEA-010', 2100, 23], ['Darjeeling First Flush', 'TEA-011', 2650, 15], ['Chamomile Flowers', 'TEA-012', 1150, 60],
      ['Lapsang Souchong', 'TEA-013', 1950, 12], ['White Peony', 'TEA-014', 2300, 9], ['Hibiscus Berry', 'TEA-015', 1200, 38],
      ['Cast Iron Teapot', 'POT-001', 6800, 8], ['Glass Infuser Mug', 'POT-002', 2200, 26], ['Bamboo Matcha Whisk', 'ACC-001', 1900, 0],
      ['Tea Strainer Set', 'ACC-002', 900, 44], ['Travel Tumbler', 'ACC-003', 2800, 19], ['Honey Sticks 20ct', 'ACC-004', 800, 90],
      ['Gift Sampler Box', 'GFT-001', 4500, 14], ['Advent Tea Calendar', 'GFT-002', 5200, 7], ['Tea Tasting Flight', 'GFT-003', 3600, 11],
      ['Loyalty Tea Card', 'GFT-004', 2500, 100]
    ].freeze

    # Weekday weights (Monday first) give each currency one clear best day: USD sells most on Saturday, CAD on Wednesday.
    STREAMS = {
      'USD' => { base: 1.8, weights: [0.8, 0.8, 1.0, 1.0, 1.5, 2.4, 1.3], sources: { 'shopify' => 40, 'square' => 30, 'rupert_pos' => 20, 'manual' => 10 }, tax: 0.0825, price: 1.0 },
      'CAD' => { base: 0.7, weights: [0.5, 0.6, 3.0, 0.8, 0.9, 1.0, 0.6], sources: { 'shopify' => 80, 'manual' => 20 }, tax: 0.13, price: 1.35 }
    }.freeze
    CHANNELS = { 'shopify' => 'online', 'square' => 'pos', 'rupert_pos' => 'pos', 'manual' => 'manual' }.freeze
    PAY_METHODS = { 'shopify' => 'card', 'square' => 'card', 'rupert_pos' => 'card', 'manual' => 'cash' }.freeze
    CUSTOMERS = [%w[Avery Quinn], %w[Mateo Alvarez], %w[Priya Nair], %w[Jonas Weber], %w[Keiko Tanaka], %w[Sam Okafor]].freeze
    CUSTOMER_WEIGHTS = [5, 3, 2, 2, 1, 1].freeze
    EMPLOYEES = [%w[Hannah Brooks], %w[Luis Ortega], %w[Fatima Rahman], %w[Owen Gallagher], %w[Mei Lin], %w[Tomas Novak]].freeze
    # employee index => status of that person's sheet for [the pay week before last, last pay week]
    SHEET_PLAN = [%w[approved approved], %w[approved approved], %w[approved submitted], %w[approved submitted],
                  %w[submitted submitted], %w[submitted draft]].freeze
    # [category, payee, base cents, day offset from FIRST_DAY]; some amounts get seeded cents on top.
    EXPENSES = [
      ['rent', 'Maple Street Properties', 240_000, 0], ['rent', 'Maple Street Properties', 240_000, 31],
      ['rent', 'Maple Street Properties', 240_000, 62], ['rent', 'Maple Street Properties', 240_000, 92],
      ['supplies', 'Packwell Supply', 31_000, 8], ['supplies', 'Packwell Supply', 27_500, 47], ['supplies', 'Packwell Supply', 36_000, 84],
      ['advertising', 'Brightside Ads', 45_000, 15], ['advertising', 'Brightside Ads', 52_000, 76],
      ['shipping', 'Northline Freight', 18_500, 22], ['shipping', 'Northline Freight', 23_000, 95],
      ['software', 'Cloudledger', 4900, 30], ['software', 'Cloudledger', 4900, 61]
    ].freeze
    TASKS = [
      # [title, due offset from today, status, priority, product it is about]
      ['Reconcile September Square deposits', -7, 'todo', 'high', nil], ['Reorder Bamboo Matcha Whisk', -5, 'in_progress', 'urgent', 'Bamboo Matcha Whisk'],
      ['Renew shop insurance', -12, 'blocked', 'medium', nil], ['Update holiday hours on the website', -18, 'todo', 'medium', nil],
      ['Pay CAD customs invoice', -1, 'todo', 'high', nil], ['File Q3 sales tax return', -7, 'done', 'high', nil],
      ['Tea shelf count', 3, 'todo', 'medium', nil], ['Reorder Jasmine Pearls', 2, 'todo', 'high', 'Jasmine Pearls'],
      ['Post Halloween tea promo', 1, 'todo', 'medium', nil], ['Check Ginger Lemon Tea lead time', 7, 'todo', 'low', 'Ginger Lemon Tea'],
      ['Train new hire on the register', 10, 'todo', 'low', nil]
    ].freeze
    # [month start, kind]; September has the most refunds, and one of them refunds a whole order.
    REFUNDS = [[Date.new(2026, 7, 1), :partial], [Date.new(2026, 8, 1), :partial], [Date.new(2026, 9, 1), :partial], [Date.new(2026, 9, 1), :partial],
               [Date.new(2026, 9, 1), :partial], [Date.new(2026, 9, 1), :full], [Date.new(2026, 10, 1), :partial], [Date.new(2026, 10, 1), :partial]].freeze

    attr_reader :tenant, :seed, :today

    def self.call(tenant:, seed: DEFAULT_SEED, today: DEFAULT_TODAY)
      new(tenant: tenant, seed: seed, today: today).call
    end

    def initialize(tenant:, seed: DEFAULT_SEED, today: DEFAULT_TODAY)
      @tenant = tenant
      @seed = seed
      @today = today
      @ledger = { orders: [], refunds: [], expenses: [], sheets: [], tasks: [], products: [], customers: [], employees: [] }
    end

    def call
      guard!
      Current.set(tenant: tenant) do
        ActiveRecord::Base.transaction do
          raise AlreadyLoaded, "Benchmark fixture data is already loaded for #{tenant.id}." if loaded?

          build
        end
      end
      self
    end

    def truth
      @truth ||= Truth.new(@ledger, today: today, seed: seed, overdue_after_days: OVERDUE_AFTER_DAYS,
        low_stock_threshold: LOW_STOCK_THRESHOLD).to_h
    end

    # The same truth as JSON text; also written to `path` when one is given.
    def truth_json(path = nil)
      json = JSON.pretty_generate(truth)
      File.write(path, "#{json}\n") if path
      json
    end

    private

    def guard!
      return unless Rails.env.production? && ENV[ALLOW_ENV] != '1'

      raise Refused, "The benchmark fixture invents data and will not run in production (set #{ALLOW_ENV}=1 to override)."
    end

    def loaded? = Core::Order.where('source_order_id LIKE ?', "#{MARKER}%").exists?

    def build
      build_catalog
      build_customers
      plan_orders
      persist_orders
      persist_refunds
      build_expenses
      build_staff
      build_tasks
    end

    # A separate generator per section keeps one section's draws from shifting another's when it changes.
    def rng(section) = Random.new(seed + section.to_s.sum * 7919)

    def pick(rng, weighted)
      point = rng.rand * weighted.values.sum
      weighted.each { |item, weight| return item if (point -= weight).negative? }
      weighted.keys.last
    end

    # --- products, stock and alerts -------------------------------------------------------------------

    def build_catalog
      location = Location.create!(source: 'shopify', externalId: "#{MARKER}#{tenant.id}-online", name: 'Online Store', primary_location: true, active: true)
      PRODUCTS.each_with_index do |(name, sku, cents, stock), index|
        create_listing(location, index, name, sku, cents, stock)
        @ledger[:products] << { name: name, sku: sku, price_cents: cents, stock: stock }
      end
    end

    def create_listing(location, index, name, sku, cents, stock)
      key = format("#{MARKER}#{tenant.id}-%02d", index + 1)
      product = ShopifyProduct.create!(id: "#{key}-p", title: name, status: 'ACTIVE', catalog_present: true, catalog_read_at: today.in_time_zone)
      variant = ShopifyVariant.create!(id: "#{key}-v", productId: product.id, title: 'Default', sku: sku, price: cents / 100.0, tracked: true,
        inventoryQuantity: stock, catalog_present: true, catalog_read_at: today.in_time_zone)
      InventoryLevel.create!(source: 'shopify', locationId: location.id, shopifyVariantId: variant.id, quantity: stock, available: stock, sourceQuantity: stock)
      return if stock > LOW_STOCK_THRESHOLD

      StockAlert.create!(shopifyVariantId: variant.id, sku: sku, quantity: stock, threshold: LOW_STOCK_THRESHOLD, status: 'open',
        note: stock.zero? ? 'Out of stock' : 'Low stock')
    end

    def build_customers
      CUSTOMERS.each_with_index do |(first, last), index|
        record = Core::Customer.create!(source: 'shopify', external_id: "#{MARKER}#{tenant.id}-c#{index + 1}", first_name: first, last_name: last,
          email: "#{first}.#{last}@benchmark.example.com".downcase)
        @ledger[:customers] << { name: "#{first} #{last}", record: record }
      end
    end

    # --- orders ---------------------------------------------------------------------------------------

    def plan_orders
      rng = rng(:orders)
      (FIRST_DAY..today).each do |date|
        STREAMS.each do |currency, spec|
          count = (spec[:weights][date.cwday - 1] * spec[:base] + rng.rand).floor
          count.times { @ledger[:orders] << plan_order(rng, date, currency, spec) }
        end
      end
      mark_queue_orders(rng(:queues))
    end

    def plan_order(rng, date, currency, spec)
      number = 1001 + @ledger[:orders].size
      source = pick(rng, spec[:sources])
      lines = Array.new(1 + rng.rand(3)) { plan_line(rng, spec) }
      subtotal = lines.sum { |line| line[:line_cents] }
      discount = rng.rand < 0.2 ? (subtotal * [10, 15].sample(random: rng) / 100.0).round : 0
      tax = ((subtotal - discount) * spec[:tax]).round
      { number: "##{number}", source: source, currency: currency, date: date, lines: lines, subtotal_cents: subtotal, discount_cents: discount,
        tax_cents: tax, gross_cents: subtotal - discount + tax, state: :fulfilled,
        at: Time.zone.local(date.year, date.month, date.day, 10 + rng.rand(10), rng.rand(60)),
        customer: (pick(rng, customer_weights) if %w[shopify manual].include?(source) && rng.rand < 0.5) }
    end

    def plan_line(rng, spec)
      product = pick(rng, product_weights)
      quantity = pick(rng, { 1 => 6, 2 => 3, 3 => 1 })
      unit = (product[:price_cents] * spec[:price]).round
      { name: product[:name], sku: product[:sku], quantity: quantity, unit_cents: unit, line_cents: unit * quantity }
    end

    def product_weights
      @product_weights ||= @ledger[:products].each_with_index.to_h { |product, index| [product, 100.0 / (index + 1)] }
    end

    def customer_weights
      @customer_weights ||= @ledger[:customers].map { |customer| customer[:name] }.zip(CUSTOMER_WEIGHTS).to_h
    end

    # A few recent online orders were never paid, and a few paid ones have not shipped yet.
    def mark_queue_orders(rng)
      online = @ledger[:orders].select { |order| order[:source] == 'shopify' }
      unpaid = online.select { |order| order[:date] >= today - 14 }.sample(4, random: rng)
      unpaid.each { |order| order[:state] = :placed }
      (online.select { |order| order[:date] >= today - 5 } - unpaid).sample(4, random: rng).each { |order| order[:state] = :paid }
    end

    def persist_orders
      by_name = @ledger[:customers].to_h { |customer| [customer[:name], customer[:record]] }
      @ledger[:orders].each_with_index do |plan, index|
        order = Core::Order.create!(order_attributes(plan, index).merge(customer: by_name[plan[:customer]]))
        plan[:lines].each_with_index do |line, position|
          order.order_lines.create!(line.merge(source_line_id: "#{order.source_order_id}-#{position + 1}"))
        end
        settle(order, plan)
        plan[:record] = order
      end
    end

    def order_attributes(plan, index)
      { source: plan[:source], source_order_id: "#{MARKER}#{plan[:source]}-#{index + 1}", order_number: plan[:number], occurred_at: plan[:at],
        created_at: plan[:at], updated_at: plan[:at], currency: plan[:currency], gross_cents: plan[:gross_cents], tax_cents: plan[:tax_cents],
        channel: CHANNELS.fetch(plan[:source]), line_items: plan[:lines].size, source_lines_complete: true,
        discount_codes: (plan[:discount_cents].positive? ? ['BENCH-LOYAL'] : []) }
    end

    def settle(order, plan)
      return if plan[:state] == :placed

      order.payments.create!(method: PAY_METHODS.fetch(plan[:source]), amount_cents: plan[:gross_cents], paid_at: plan[:at], status: 'completed')
      order.mark_paid!
      return if plan[:state] == :paid

      order.fulfill!
      order.update!(fulfillment_status: 'completed')
    end

    # --- refunds --------------------------------------------------------------------------------------

    def persist_refunds
      rng = rng(:refunds)
      REFUNDS.each do |month, kind|
        plan = refundable(rng, month) or next
        amount = kind == :full ? plan[:gross_cents] : [plan[:lines].first[:line_cents], plan[:gross_cents] / 2].min
        refunded_on = [plan[:date] + rng.rand(1..5), month.end_of_month, today].min
        plan[:record].record_refund!(amount_cents: amount, method: PAY_METHODS.fetch(plan[:source]), reason: 'Benchmark refund',
          refunded_at: refunded_on.in_time_zone.change(hour: 12))
        plan[:refunded] = true
        plan[:fully_refunded] = kind == :full
        @ledger[:refunds] << { date: refunded_on, source: plan[:source], currency: plan[:currency], amount_cents: amount, order: plan[:number] }
      end
    end

    def refundable(rng, month)
      candidates = @ledger[:orders].select do |plan|
        plan[:state] == :fulfilled && !plan[:refunded] && plan[:date].beginning_of_month == month && plan[:date] <= today - 7
      end
      candidates.sample(random: rng)
    end

    # --- expenses -------------------------------------------------------------------------------------

    def build_expenses
      rng = rng(:expenses)
      EXPENSES.each do |category, payee, cents, offset|
        amount = category == 'rent' ? cents : cents + rng.rand(0..99) * 25
        date = FIRST_DAY + offset
        Finance::Expense.create!(category: category, payee: payee, amount_cents: amount, incurred_on: date, method: 'card', notes: 'Benchmark expense')
        @ledger[:expenses] << { category: category, amount_cents: amount, date: date }
      end
    end

    # --- employees and timesheets ---------------------------------------------------------------------

    def build_staff
      rng = rng(:staff)
      employees = EMPLOYEES.each_with_index.map { |(first, last), index| create_employee(first, last, index) }
      weeks = [pay_week_start - 14, pay_week_start - 7]
      employees.each_with_index do |employee, index|
        weeks.each_with_index do |from, week|
          create_sheet(rng, employee, from, SHEET_PLAN.dig(index, week))
        end
      end
    end

    # Rupert's default pay week runs Thursday to Wednesday; the current one may still be open, so the
    # last two completed weeks are the ones before it.
    def pay_week_start = today - ((today.cwday - 4) % 7)

    def create_employee(first, last, index)
      employee = People::Employee.create!(first_name: first, last_name: last, employee_number: format('BF-%03d', index + 1),
        email: "#{first}.#{last}@benchmark.example.com".downcase, employment_type: index < 3 ? 'full_time' : 'part_time', hire_date: FIRST_DAY - 200)
      @ledger[:employees] << { name: "#{first} #{last}" }
      employee
    end

    def create_sheet(rng, employee, from, status)
      to = from + 6
      sheet = People::Timesheet.create!(employee: employee, period_start: from, period_end: to)
      entries = work_days(rng, from).map do |date|
        hours = rng.rand(8..16) / 2.0 # whole and half hours, 4 to 8 a day
        # Validations compare against the real clock; `today` is a parameter here, so the rows are saved as they are.
        sheet.entries.new(worked_on: date, hours: hours, work_type: 'regular', tenant_id: tenant.id).save!(validate: false)
        { date: date, hours: hours }
      end
      submitted_on = advance(sheet, status, to)
      @ledger[:sheets] << { employee: employee.name, from: from, to: to, status: status, entries: entries, submitted_on: submitted_on }
    end

    def work_days(rng, from) = (0..6).to_a.sample(rng.rand(3..5), random: rng).sort.map { |offset| from + offset }

    # Submitted the day after the week ends; approved ones were reviewed two days later. Sheets from the older
    # week that are still submitted are the overdue approvals.
    def advance(sheet, status, week_end)
      submitted_on = week_end + 1
      return submitted_on if status == 'draft'

      sheet.submit!
      sheet.update_columns(submitted_at: submitted_on.in_time_zone.change(hour: 17))
      return submitted_on if status == 'submitted'

      sheet.approve!
      sheet.update_columns(reviewed_at: (submitted_on + 2).in_time_zone.change(hour: 10))
      submitted_on
    end

    # --- tasks ----------------------------------------------------------------------------------------

    def build_tasks
      TASKS.each do |title, offset, status, priority, product|
        task = Projects::Task.create!(title: title, due_on: today + offset, priority: priority, description: 'Benchmark task')
        move(task, status)
        @ledger[:tasks] << { title: title, due_on: today + offset, status: status, product: product }
      end
    end

    def move(task, status)
      case status
      when 'in_progress' then task.start!
      when 'done' then task.finish!
      when 'blocked' then task.block_with_reason!('Waiting on the broker')
      end
    end
  end
end
