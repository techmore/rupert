# frozen_string_literal: true

# App Store review workspace: a fictional shop ("Juniper & Pine Market") that Apple's
# reviewer signs in to from the iPhone app. Everything lives in its own tenant
# (subdomain app-review-demo); no other workspace is read or written.
#
#   REVIEW_PASSWORD='…' bin/rails rupert:app_review_demo
#   REVIEW_PASSWORD='…' REVIEW_DEMO_RESET=1 bin/rails rupert:app_review_demo
#
# The password is typed by the owner and only stored as the account's password hash;
# it is never printed, logged or written to a file. Sign-in: appreview@rupertpos.com,
# role admin of the demo workspace only (never super_admin, which sees every workspace).
#
# Safe to run again: the tenant, people, catalog, stock, chat, tasks and notifications
# are matched by fixed keys, and sales are keyed by day, so a later run only adds the
# days since the last one. REVIEW_DEMO_RESET=1 first deletes every row of the demo
# workspace except its people and settings, then rebuilds it with today's dates, which
# is the way to freshen the data before a new review.
module AppReviewDemo
  SUBDOMAIN = 'app-review-demo'
  NAME = 'Juniper & Pine Market'
  EMAIL = 'appreview@rupertpos.com'
  KEY = 'app-review-demo'
  MIN_PASSWORD = 12
  SALE_DAYS = 30
  # Kept on reset: the accounts, the workspace itself and its configuration and audit trail.
  KEEP_ON_RESET = %w[users tenants settings api_access_tokens user_permissions activity_logs access_logs].freeze

  # Fictional colleagues. They never sign in: each gets a long random password nobody sees.
  PEOPLE = [
    { key: :maya, email: 'maya.chen@juniper-pine.example', name: 'Maya Chen', role: 'admin' },
    { key: :theo, email: 'theo.alvarez@juniper-pine.example', name: 'Theo Alvarez', role: 'admin' },
    { key: :priya, email: 'priya.shah@juniper-pine.example', name: 'Priya Shah', role: 'cashier' },
    # The hourly worker the reviewer can also sign in as (Time tab): their password is REVIEW_WORKER_PASSWORD,
    # or the review password when that is not set. Never printed.
    { key: :worker, email: 'sam.okafor@juniper-pine.example', name: 'Sam Okafor', role: 'employee' }
  ].freeze
  WORKER_PIN = '2580'

  # handle, product title, variant title, type, price, shop shelf, back stockroom
  CATALOG = [
    ['cedar-smoke-candle', 'Cedar & Smoke Soy Candle', '8 oz jar', 'Candles', 24_00, 14, 24],
    ['wild-fig-candle', 'Wild Fig Soy Candle', '8 oz jar', 'Candles', 24_00, 2, 0],
    ['morning-ridge-coffee', 'Morning Ridge Coffee', '12 oz bag', 'Coffee & tea', 16_50, 18, 30],
    ['night-owl-decaf', 'Night Owl Decaf', '12 oz bag', 'Coffee & tea', 16_50, 9, 12],
    ['chamomile-tea', 'Chamomile Loose Tea', '3 oz tin', 'Coffee & tea', 11_00, 11, 16],
    ['speckled-mug', 'Speckled Stoneware Mug', 'Speckled', 'Kitchen', 18_00, 8, 20],
    ['linen-tea-towel', 'Linen Tea Towel', 'Natural', 'Kitchen', 14_00, 12, 18],
    ['oat-honey-soap', 'Oat & Honey Bar Soap', '5 oz bar', 'Bath & body', 8_50, 22, 40],
    ['lavender-hand-cream', 'Lavender Hand Cream', '2 oz tube', 'Bath & body', 15_00, 7, 10],
    ['beeswax-lip-balm', 'Beeswax Lip Balm', 'Tube', 'Bath & body', 5_00, 0, 0],
    ['pocket-notebooks', 'Pocket Notebooks, Set of 3', 'Kraft cover', 'Paper goods', 12_00, 15, 25],
    ['pressed-flower-card', 'Pressed Flower Card', 'Blank inside', 'Paper goods', 6_00, 30, 60]
  ].freeze

  # minutes ago, author key, text
  CHAT = [
    [1_120, :theo, 'Candle delivery is in the back room: four cases of Cedar & Smoke, the Wild Fig is still on backorder.'],
    [1_095, :maya, 'Thanks Theo. Wild Fig is down to two on the front table. Can we move a Cedar & Smoke display next to it?'],
    [1_080, :theo, 'Done, and I put a "back soon" card on the Wild Fig shelf.'],
    [210, :maya, 'Morning! I started this week\'s shelf count for the front wall. Scan as you go when you have a minute.'],
    [195, :sam, 'Will do after the lunch rush. Lip balm is sold out, I added it to the reorder list.'],
    [40, :maya, 'Great. Coffee is selling well this week, let\'s keep an eye on Morning Ridge.']
  ].freeze

  module_function

  def run!(password:, reset: false, now: Time.current, worker_password: nil)
    raise ArgumentError, "REVIEW_PASSWORD must be at least #{MIN_PASSWORD} characters" if password.to_s.length < MIN_PASSWORD

    tenant = ensure_tenant!
    user = ensure_reviewer!(tenant, password)
    Current.set(tenant: tenant, user: user) do
      wipe!(tenant) if reset
      people = ensure_people!(tenant).merge(sam: user)
      people[:worker].update!(password: worker_password.presence || password)
      locations = ensure_locations!
      variants = ensure_catalog!(locations, now)
      orders = ensure_sales!(variants, locations[:shop], now)
      count = ensure_count!(variants, locations[:shop], people[:maya], now)
      tasks = ensure_tasks!(people, now)
      ensure_notifications!(user, people, tasks, count, now)
      ensure_chat!(people, now)
      ensure_time!(people, locations[:shop], now)
      DataCache.bump!
      settle_reviewer!(user)
      { tenant: tenant, user: user, orders: orders, count: count }
    end
  end

  # The reviewer lands in a shop that is already set up: the first-run welcome and the page tours are
  # marked seen (both stay in Learning), and the bookkeeping checks this fictional shop has no paperwork
  # for (register reports, month close, backups) are marked Done, exactly as the Next bar's Done button
  # does. They come back when they change; stock alerts and tasks stay in the bar.
  def settle_reviewer!(user)
    journey = LearningJourney.new(user)
    journey.dismiss!
    PageTours.all.each { |tour| journey.complete_tour!(tour.key) if PageTours.permitted?(tour, user) }
    Rails.cache.delete(['next_things', user.tenant_id, user.id])
    things = NextThings.new(user)
    things.all.each { |item| things.dismiss!(item[:key], 'done') if item[:key].start_with?('check:') }
  end

  def ensure_tenant!
    tenant = Tenant.find_by(subdomain: SUBDOMAIN)
    if tenant && tenant.name != NAME
      raise ArgumentError, "Workspace #{SUBDOMAIN} exists but is named #{tenant.name.inspect}, not #{NAME.inspect}; refusing to touch it"
    end

    # Checked before anything is written: an account of these addresses in another workspace stays where it is.
    taken = User.where(email: [EMAIL, *PEOPLE.pluck(:email)]).reject { |user| tenant && user.tenant_id == tenant.id }.map(&:email)
    raise ArgumentError, "#{taken.to_sentence} already belong(s) to another workspace; refusing to move it" if taken.any?

    tenant ||= Tenant.create!(name: NAME, subdomain: SUBDOMAIN, status: 'active')
    tenant.update!(status: 'active') unless tenant.status == 'active'
    tenant
  end

  def ensure_reviewer!(tenant, password)
    user = User.find_by(email: EMAIL, tenant_id: tenant.id) || User.new(email: EMAIL, tenant: tenant)
    user.assign_attributes(name: 'Sam Porter', role: 'admin', active: true, password: password)
    user.save!
    user
  end

  def ensure_people!(tenant)
    PEOPLE.to_h do |person|
      user = User.find_by(email: person[:email], tenant_id: tenant.id) ||
             User.new(email: person[:email], tenant: tenant, password: SecureRandom.base58(40))
      user.assign_attributes(name: person[:name], role: person[:role], active: true)
      user.save!
      [person[:key], user]
    end
  end

  def ensure_locations!
    {
      shop: location!('shop', 'Main Street Shop', primary: true),
      back: location!('back-room', 'Back Stockroom', primary: false)
    }
  end

  def location!(key, name, primary:)
    location = Location.find_or_initialize_by(source: 'shopify', externalId: "#{KEY}-#{key}")
    location.update!(name: name, active: true, primary_location: primary, timezone: Time.zone.tzinfo.name, syncedAt: Time.current)
    location
  end

  # A small store catalog with stock on the shop floor and in the back room. Two items are low or
  # sold out, which gives the dashboard's "Needs attention" list something true to say.
  def ensure_catalog!(locations, now)
    CATALOG.each_with_index.to_h do |(handle, title, variant_title, type, price, shop_qty, back_qty), index|
      product = ShopifyProduct.find_or_initialize_by(id: "#{KEY}-product-#{handle}")
      product.update!(title: title, handle: handle, vendor: NAME, productType: type, status: 'ACTIVE', catalog_present: true,
        catalog_read_at: now, publishedAt: product.publishedAt || (now - 90.days), syncedAt: now, totalInventory: shop_qty + back_qty)
      sku = format('JP-%04d', 1001 + index)
      variant = ShopifyVariant.find_or_initialize_by(sku: sku, productId: product.id)
      variant.update!(title: variant_title, price: price / 100.0, barcode: barcode(index), inventoryItemId: "#{KEY}-item-#{handle}",
        inventoryQuantity: shop_qty + back_qty, tracked: true, catalog_present: true, catalog_read_at: now, syncedAt: now)
      { locations[:shop] => shop_qty, locations[:back] => back_qty }.each do |location, quantity|
        level = InventoryLevel.find_or_initialize_by(source: 'shopify', locationId: location.id, shopifyVariantId: variant.id)
        level.update!(quantity: quantity, available: quantity, sourceQuantity: quantity, updatedAt: now)
      end
      stock_alert!(variant, shop_qty + back_qty) if shop_qty + back_qty <= 5
      [handle, { variant: variant, price: price, name: "#{title} · #{variant_title}" }]
    end
  end

  # EAN-13 in the 200–299 "in-store use" range, so it can never match a real product.
  def barcode(index)
    digits = format('200%09d', 4_210_000 + index)
    sum = digits.chars.each_with_index.sum { |digit, i| digit.to_i * (i.even? ? 1 : 3) }
    "#{digits}#{(10 - (sum % 10)) % 10}"
  end

  def stock_alert!(variant, quantity)
    alert = StockAlert.find_or_initialize_by(sku: variant.sku, status: 'open')
    alert.update!(shopifyVariantId: variant.id, quantity: quantity, threshold: 5,
      note: quantity.zero? ? 'Sold out on the shop floor and in the back room' : 'Low on the shop floor')
  end

  # In-store sales rung up in Rupert POS over the last 30 days: more on weekends, nothing before
  # opening or after now. Each day's orders come from a generator seeded by the date, so a re-run
  # recreates the same orders and only adds what is new.
  def ensure_sales!(variants, shop, now)
    items = variants.values
    created = 0
    (0...SALE_DAYS).each do |days_ago|
      date = now.to_date - days_ago
      random = Random.new(date.jd)
      count = (date.saturday? || date.sunday? ? 16 : 10) + random.rand(6)
      times = Array.new(count) { date.in_time_zone.change(hour: 10) + random.rand(8 * 60).minutes }.sort
      times.each_with_index do |at, number|
        lines = Array.new(1 + random.rand(3)) { [items[random.rand(items.size)], 1 + (random.rand(4).zero? ? 1 : 0)] }
        next if at > now

        source_order_id = "#{KEY}-#{date.iso8601}-#{number + 1}"
        next if Core::Order.exists?(source: 'rupert_pos', source_order_id: source_order_id)

        create_order!(source_order_id, format('JP-%s-%02d', date.strftime('%m%d'), number + 1), at, lines, shop)
        created += 1
      end
    end
    created
  end

  def create_order!(source_order_id, number, at, lines, shop)
    subtotal = lines.sum { |item, quantity| item[:price] * quantity }
    tax = (subtotal * 0.06).round
    Core::Order.transaction do
      order = Core::Order.create!(source: 'rupert_pos', source_order_id: source_order_id, order_number: number, channel: 'pos',
        occurred_at: at, currency: 'USD', gross_cents: subtotal + tax, tax_cents: tax, line_items: lines.sum(&:last),
        location_id: shop.externalId, source_lines_complete: true, fulfillment_status: 'completed')
      lines.each_with_index do |(item, quantity), index|
        variant = item[:variant]
        order.order_lines.create!(name: item[:name], sku: variant.sku, quantity: quantity, unit_cents: item[:price],
          line_cents: item[:price] * quantity, source_line_id: "#{source_order_id}-#{index + 1}", source_variant_id: variant.id)
      end
      order.mark_paid!
    end
  end

  # A draft shelf count, so the app's barcode scanner (inventory_counts/:id/scan) has somewhere to count.
  def ensure_count!(variants, shop, maya, now)
    count = InventoryCount.find_or_initialize_by(note: 'Front wall · weekly shelf count')
    if count.new_record?
      count.assign_attributes(locationId: shop.id, countedAt: now - 3.hours, createdBy: maya.email)
      count.save!
    end
    return count unless count.draft?

    { 'morning-ridge-coffee' => 17, 'speckled-mug' => 8, 'pocket-notebooks' => 15 }.each do |handle, quantity|
      variant = variants.fetch(handle)[:variant]
      item = count.items.find_or_initialize_by(sku: variant.sku)
      item.update!(shopifyVariantId: variant.id, quantity: quantity) if item.new_record?
    end
    count
  end

  def ensure_tasks!(people, now)
    project = Projects::Project.find_or_initialize_by(name: 'Holiday window display')
    if project.new_record?
      project.assign_attributes(owner_id: people[:maya].id.to_s, start_on: now.to_date - 3, due_on: now.to_date + 18,
        description: 'Refresh the front window and the candle table for the holidays.')
      project.save!
      project.start!
    end
    [
      [:reorder, 'Reorder Wild Fig candles and lip balm', 'high', 1, 'Both are out or nearly out. Check the supplier\'s lead time.'],
      [:count, 'Finish the front wall shelf count', 'medium', 0, 'Draft count started by Maya. Scan each shelf, then submit for approval.'],
      [:mugs, 'Price the new stoneware mugs', 'low', 4, 'Twenty speckled mugs arrived with the candle delivery.']
    ].to_h do |key, title, priority, due_in, description|
      task = Projects::Task.find_or_initialize_by(project_id: project.id, title: title)
      if task.new_record?
        task.assign_attributes(assignee_id: people[:sam].id.to_s, requester_id: people[:maya].id.to_s, priority: priority,
          due_on: now.to_date + due_in, description: description)
        task.save!
      end
      [key, task]
    end
  end

  def ensure_notifications!(user, people, tasks, count, now)
    helpers = Rails.application.routes.url_helpers
    maya = people[:maya].name
    [
      [:assigned, 'task_assigned', "#{maya} assigned you: #{tasks[:reorder].title}", 'Holiday window display', helpers.projects_task_path(tasks[:reorder]), 25, false],
      [:due, 'task_due', "Due today: #{tasks[:count].title}", 'Holiday window display', helpers.projects_task_path(tasks[:count]), 180, false],
      [:scan, 'task_comment', "#{maya} commented on: #{tasks[:count].title}", 'Front wall is started; the scanner picks up where I left off.',
       helpers.scan_inventory_count_path(count), 205, false],
      [:mugs, 'task_assigned', "#{maya} assigned you: #{tasks[:mugs].title}", 'Holiday window display', helpers.projects_task_path(tasks[:mugs]), 1_500, true]
    ].each do |key, kind, title, body, url, minutes_ago, read|
      notification = Notification.find_or_initialize_by(user_id: user.id, dedupe_key: "#{KEY}-#{key}")
      next unless notification.new_record?

      at = now - minutes_ago.minutes
      notification.update!(kind: kind, title: title, body: body, url: url, created_at: at, updated_at: at, read_at: (at + 1.hour if read))
    end
  end

  # A shop-floor channel with a few messages between colleagues. @rupert only answers when
  # mentioned here, so the room reads honestly without any assistant replies.
  def ensure_chat!(people, now)
    TeamChat::Room.ensure_defaults!(people[:sam])
    room = TeamChat::Room.find_or_initialize_by(slug: 'shop-floor')
    if room.new_record?
      room.assign_attributes(name: 'shop-floor', kind: 'channel', assistant_mode: 'mentions', created_by: people[:maya],
        topic: 'Day-to-day at the shop: deliveries, displays and who is on the floor.')
      room.save!
    end
    room.add_members(people.values_at(:maya, :theo, :sam))
    if room.messages.none?
      CHAT.each do |minutes_ago, author, body|
        at = now - minutes_ago.minutes
        room.messages.create!(user: people.fetch(author), author_kind: 'person', status: 'done', body: body, created_at: at, updated_at: at)
      end
      room.update_columns(last_message_at: now - CHAT.last.first.minutes)
    end
    # Opening Team Chat shows the room whose membership was touched last.
    room.membership_for(people[:sam]).update_columns(updated_at: Time.current)
    room
  end

  # Deletes the demo workspace's rows, table by table, matching only its tenant id.
  # ---- Time & pay (the Time tab) -------------------------------------------------------------
  # Staff records for Maya (manager, admin: no tip share), Priya and the worker, hourly rates, the
  # worker's clock PIN, two weeks of punches with a meal break, next week's published shifts, time
  # off (one approved, one waiting), this week's tips and a submitted timesheet. Keyed so a second
  # run changes nothing it already made.
  def ensure_time!(people, shop, now)
    staff = {
      maya: staff!(people[:maya], 'Maya', 'Chen', 2600, number: '1001'),
      priya: staff!(people[:priya], 'Priya', 'Shah', 1900, number: '1002'),
      worker: staff!(people[:worker], 'Sam', 'Okafor', 1850, number: '1003')
    }
    staff[:worker].set_pin!(WORKER_PIN) unless staff[:worker].pin_set?
    staff.each_value { |employee| employee.update!(location_ids: [shop.id]) if employee.location_ids.empty? }
    ensure_punches!(staff, shop, now)
    ensure_shifts!(staff, shop, now)
    ensure_time_off!(staff, people[:maya], now)
    ensure_tips!(staff, shop, now)
    ensure_timesheet!(staff[:worker], now)
  end

  def staff!(user, first, last, rate_cents, number:)
    employee = People::Employee.find_or_initialize_by(user_id: user.id)
    if employee.new_record?
      employee.assign_attributes(first_name: first, last_name: last, email: user.email, employee_number: number,
        employment_type: 'part_time', hire_date: Date.new(2025, 3, 3))
      employee.save!
    end
    People::PayRate.find_or_create_by!(employee_id: employee.id, pay_type: 'hourly', effective_on: Date.new(2025, 3, 3)) do |rate|
      rate.hourly_rate_cents = rate_cents
      rate.pay_frequency = 'weekly'
    end
    employee
  end

  # Weekday shifts over the last two weeks, 9 to 5 with a 30-minute meal; yesterday has a rest break too.
  def ensure_punches!(staff, shop, now)
    zone = BusinessClock.zone(tenant: Current.tenant, location: shop)
    (1..14).each do |days_ago|
      day = now.in_time_zone(zone).to_date - days_ago
      next if day.saturday? || day.sunday?

      { worker: [9, 17], priya: [10, 18] }.each do |key, (from, to)|
        employee = staff[key]
        token = "demo-#{key}-#{day.iso8601}"
        next if ClockShift.exists?(request_token: token)

        started = zone.local(day.year, day.month, day.day, from, [2, 0, 4, 1][days_ago % 4])
        ended = zone.local(day.year, day.month, day.day, to, [1, 6, 0, 3][days_ago % 4])
        shift = ClockShift.create!(user: employee.user, employee: employee, employee_key: employee.id.to_s, employee_name: employee.name,
          employment_type: employee.employment_type, request_token: token, started_at: started, ended_at: ended,
          source: 'pos', location_id: shop.id, register_name: 'Front register', device_label: 'Front register')
        shift.breaks.create!(kind: 'meal', paid: false, started_at: started + 4.hours, ended_at: started + 4.hours + 30.minutes)
        shift.breaks.create!(kind: 'rest', paid: true, started_at: started + 2.hours, ended_at: started + 2.hours + 10.minutes) if days_ago == 1
      end
    end
  end

  # Next week's shifts, published, plus one open shift to pick up.
  def ensure_shifts!(staff, shop, now)
    zone = BusinessClock.zone(tenant: Current.tenant, location: shop)
    week = (now.in_time_zone(zone).to_date + 7).beginning_of_week
    pattern = { worker: [[0, 9, 17], [1, 9, 17], [3, 12, 20], [4, 9, 17]], priya: [[0, 10, 18], [2, 10, 18], [3, 9, 17], [5, 10, 16]], maya: [[1, 8, 16], [2, 8, 16], [4, 8, 16]] }
    pattern.each do |key, days|
      days.each do |(offset, from, to)|
        day = week + offset
        starts_at = zone.local(day.year, day.month, day.day, from)
        next if People::ScheduledShift.exists?(employee_id: staff[key].id, starts_at: starts_at)

        People::ScheduledShift.create!(employee: staff[key], starts_at: starts_at, ends_at: zone.local(day.year, day.month, day.day, to),
          role_label: key == :maya ? 'Manager' : 'Counter', location_id: shop.id, break_minutes: 30, published_at: now - 2.days, created_by: staff[:maya].user)
      end
    end
    saturday = week + 5
    open_start = zone.local(saturday.year, saturday.month, saturday.day, 12)
    unless People::ScheduledShift.exists?(employee_id: nil, starts_at: open_start)
      People::ScheduledShift.create!(employee: nil, starts_at: open_start, ends_at: open_start + 6.hours, role_label: 'Counter',
        location_id: shop.id, break_minutes: 0, published_at: now - 2.days, created_by: staff[:maya].user, notes: 'Holiday market weekend: extra hands at the counter.')
    end
    People::SchedulePublication.find_or_create_by!(location_id: shop.id, week_start: week) do |publication|
      publication.published_at = now - 2.days
      publication.published_by = staff[:maya].user
      publication.shift_count = People::ScheduledShift.between(week, week + 6).count
    end
  end

  def ensure_time_off!(staff, maya, now)
    worker = staff[:worker]
    approved = People::LeaveRequest.find_or_initialize_by(employee_id: worker.id, request_key: 'demo-worker-approved')
    if approved.new_record?
      approved.assign_attributes(leave_type: 'vacation', starts_on: now.to_date + 21, ends_on: now.to_date + 23, hours: 24, reason: 'Long weekend away.')
      approved.save!
      approved.approve!
      approved.update!(reviewed_by: maya.id, reviewed_at: now - 1.day)
    end
    pending = People::LeaveRequest.find_or_initialize_by(employee_id: worker.id, request_key: 'demo-worker-pending')
    if pending.new_record?
      pending.assign_attributes(leave_type: 'personal', starts_on: now.to_date + 10, ends_on: now.to_date + 10, hours: 8, reason: 'Dentist in the morning.')
      pending.save!
    end
    worker.leave_balance('vacation').tap { |b| b.update!(used_hours: 24) if b.used_hours.zero? }
  end

  # Card tips shared between the two staff on shift and a cash tip the worker declared, this week.
  def ensure_tips!(staff, shop, now)
    zone = BusinessClock.zone(tenant: Current.tenant, location: shop)
    (1..5).each do |days_ago|
      day = now.in_time_zone(zone).to_date - days_ago
      next if day.saturday? || day.sunday?

      ref = "demo-tip-#{day.iso8601}"
      next if TipAllocation.exists?(source_ref: ref)

      at = zone.local(day.year, day.month, day.day, 13, 15)
      gross = 1200 + (days_ago * 325)
      %i[worker priya].each_with_index do |key, index|
        employee = staff[key]
        shift = ClockShift.find_by(employee_id: employee.id, request_token: "demo-#{key}-#{day.iso8601}")
        TipAllocation.create!(employee: employee, clock_shift: shift, location_id: shop.id, source_kind: 'manual', source_ref: ref,
          tip_method: 'pool', status: days_ago > 2 ? 'settled' : 'estimated', amount_cents: (gross / 2) + (index.zero? ? gross % 2 : 0),
          gross_tip_cents: gross, share_count: 2, occurred_at: at, business_date: day, evidence: 'time_register',
          settled_at: days_ago > 2 ? at + 1.day : nil, note: 'Card tips from the front register, shared evenly.')
      end
      next unless days_ago == 1

      TipAllocation.create!(employee: staff[:worker], location_id: shop.id, source_kind: 'declared', source_ref: "#{ref}-cash", tip_method: 'cash',
        status: 'settled', amount_cents: 1400, occurred_at: at + 4.hours, business_date: day, evidence: 'declared', created_by: staff[:worker].user,
        note: 'Cash tips declared at clock-out.')
    end
  end

  # Last week's timesheet, built from the punches and sent for review.
  def ensure_timesheet!(worker, now)
    rules = PayRules.current
    period_start, period_end = rules.period_range(now.to_date - 7)
    return if People::Timesheet.exists?(employee_id: worker.id, period_start: period_start)

    sheet = People::Timesheet.create!(employee: worker, period_start: period_start, period_end: period_end, notes: 'Covered the Thursday delivery.')
    ClockShift.where(employee_id: worker.id).where.not(ended_at: nil).where(started_at: period_start.in_time_zone..(period_end + 1).in_time_zone).find_each do |shift|
      sheet.entries.create!(worked_on: shift.started_at.to_date, hours: shift.paid_hours.round(2), work_type: 'regular', clock_shift_id: shift.id)
    end
    sheet.submit! if sheet.entries.any?
    sheet.update!(submitted_at: now - 1.day) if sheet.submitted?
  end

  def wipe!(tenant)
    connection = ActiveRecord::Base.connection
    tables = connection.tables.reject { |table| KEEP_ON_RESET.include?(table) }
      .select { |table| connection.column_exists?(table, :tenant_id) }
    connection.disable_referential_integrity do
      connection.transaction do
        tables.each do |table|
          connection.exec_delete(
            ActiveRecord::Base.sanitize_sql_array(["DELETE FROM #{connection.quote_table_name(table)} WHERE tenant_id = ?", tenant.id]),
            'AppReviewDemo wipe')
        end
      end
    end
  end
end

namespace :rupert do
  desc 'Create or refresh the fictional App Store review workspace (REVIEW_PASSWORD required, REVIEW_DEMO_RESET=1 to rebuild)'
  task app_review_demo: :environment do
    password = ENV['REVIEW_PASSWORD'].to_s
    if password.length < AppReviewDemo::MIN_PASSWORD
      abort("Set REVIEW_PASSWORD to the review account's password (at least #{AppReviewDemo::MIN_PASSWORD} characters).")
    end

    result = AppReviewDemo.run!(password: password, reset: ENV['REVIEW_DEMO_RESET'].present?, worker_password: ENV.fetch('REVIEW_WORKER_PASSWORD', nil))
    puts "#{AppReviewDemo::NAME} ready (workspace #{AppReviewDemo::SUBDOMAIN})."
    puts "Sign in as #{result[:user].email} (admin of this workspace only) with the password you set."
    puts "Added #{result[:orders]} sample sales; draft count #{result[:count].id}."
    puts "Worker sign-in for the Time tab: sam.okafor@juniper-pine.example (REVIEW_WORKER_PASSWORD, or the review password); clock PIN #{AppReviewDemo::WORKER_PIN}."
  rescue ArgumentError => e
    abort(e.message)
  end
end
