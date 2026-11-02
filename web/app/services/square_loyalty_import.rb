# frozen_string_literal: true

# Mirrors Square Loyalty into Rupert, read-only. Program, reward tiers, promotions
# and member accounts are read in full and published together, or not at all.
# The points ledger is read newest first and stored page by page by Square event
# ID, so re-running never duplicates an event; only a complete read moves the
# ledger position forward. Nothing is ever written to Square.
#
# Dry run (the default) reads the program, promotions, members and the newest
# ledger page and reports what would be stored.
class SquareLoyaltyImport
  Error = SquareLoyaltyReader::Error
  # Re-read this much of the ledger before the last complete read, so late or
  # clock-skewed events are not missed. Events already stored are skipped.
  OVERLAP = 1.day
  MAX_PENDING_WINDOWS = 20

  def initialize(actor: Current.user, sync_configuration: nil, reader: SquareLoyaltyReader.new)
    @actor = actor
    @sync_configuration = sync_configuration
    @reader = reader
  end

  def call(apply: false)
    authorize!
    @started_at = Time.current
    @reader.check_access!
    program = @reader.program
    return no_program(apply) unless program

    promotions = @reader.promotions(program['id'])
    accounts = @reader.accounts.map { |row| normalize_account(row) }
    return preview(program, promotions, accounts) unless apply

    publish(program, promotions, accounts)
    events = sync_events
    stats = summary(program, accounts).merge(events)
    finish!(stats)
    stats
  end

  private

  def authorize!
    @actor = SquareLoyaltySync.authorized_actor(@actor&.id)
    raise Pundit::NotAuthorizedError unless @actor && Tenant.exists?(id: Current.tenant_id, status: 'active')
  end

  def lock_and_verify!
    raise ActiveRecord::RecordNotFound unless Tenant.where(id: Current.tenant_id).update_all('updated_at = updated_at') == 1

    authorize!
    SquareLoyaltySync.verify!(@sync_configuration) if @sync_configuration
    @reader.verify_connection!
    known = SquareLoyaltySync.state['merchant_id']
    if known.present? && @reader.merchant_id.present? && known != @reader.merchant_id
      raise Error.new('The saved Square token belongs to a different Square account than the loyalty data already in Rupert. Nothing was changed.', reason: :identity)
    end
  end

  def no_program(apply)
    result = { program: nil, members: 0, scope: @reader.scope_status }
    return result unless apply

    SquareLoyaltyAccount.transaction do
      lock_and_verify!
      SquareLoyaltyProgram.where.not(status: 'MISSING').update_all(status: 'MISSING', updated_at: Time.current)
    end
    finish!(result)
    result
  end

  def preview(program, promotions, accounts)
    linked = SquareLoyaltyAccount.customers_by_square_id(accounts.map { |attrs| attrs[:square_customer_id] })
    newest = nil
    @reader.each_event_page(max_pages: 1) { |page| newest ||= page.first&.dig('created_at') }
    summary(program, accounts).merge(promotions: promotions.size, linked_customers: accounts.count { |attrs| linked.key?(attrs[:square_customer_id]) },
      newest_event_at: newest, stored_members: SquareLoyaltyAccount.count, stored_events: SquareLoyaltyEvent.count, dry_run: true)
  end

  def summary(program, accounts)
    { program: program['id'], program_status: program['status'], reward_tiers: Array(program['reward_tiers']).size, members: accounts.size,
      points_outstanding: accounts.sum { |attrs| attrs[:balance] }, scope: @reader.scope_status }
  end

  # Program, tiers, promotions and members in one transaction: all or nothing.
  def publish(program, promotions, accounts)
    SquareLoyaltyAccount.transaction do
      lock_and_verify!
      if SquareLoyaltyAccount.where('last_seen_at > ?', @started_at).exists?
        raise Error.new('A newer Square loyalty read was already saved. Nothing was changed; the next run will read again.', reason: :stale)
      end

      now = Time.current
      record = publish_program(program, now)
      publish_tiers(record, program, now)
      publish_promotions(record, promotions, now)
      publish_accounts(accounts, now)
    end
  end

  def publish_program(row, now)
    record = SquareLoyaltyProgram.find_or_initialize_by(external_id: row['id'])
    terms = row['terminology'].is_a?(Hash) ? row['terminology'] : {}
    record.update!(status: string(row['status']), terminology_one: string(terms['one']), terminology_other: string(terms['other']),
      expiration_duration: string(row.dig('expiration_policy', 'expiration_duration')),
      location_ids: JSON.generate(Array(row['location_ids']).select { |id| @reader.valid_id?(id) }),
      accrual_rules: JSON.generate(Array(row['accrual_rules']).filter_map { |rule| accrual_rule(rule) }),
      source_created_at: @reader.timestamp(row['created_at']), source_updated_at: @reader.timestamp(row['updated_at']), last_seen_at: now)
    SquareLoyaltyProgram.where.not(id: record.id).where.not(status: 'MISSING').update_all(status: 'MISSING', updated_at: now)
    record
  end

  def accrual_rule(rule)
    return unless rule.is_a?(Hash) && rule['accrual_type'].is_a?(String)

    money = rule.dig('spend_data', 'amount_money') || rule.dig('visit_data', 'minimum_amount_money')
    { 'accrual_type' => rule['accrual_type'], 'points' => integer(rule['points']),
      'amount_cents' => money.is_a?(Hash) ? integer(money['amount']) : nil, 'currency' => money.is_a?(Hash) ? string(money['currency']) : nil,
      'tax_mode' => string(rule.dig('spend_data', 'tax_mode') || rule.dig('visit_data', 'tax_mode')),
      'item_variation_id' => string(rule.dig('item_variation_data', 'item_variation_id')), 'category_id' => string(rule.dig('category_data', 'category_id')) }.compact
  end

  def publish_tiers(program, row, now)
    tiers = Array(row['reward_tiers'])
    raise Error, 'Square returned unreadable loyalty reward tiers. Previous loyalty data was kept.' unless tiers.all? { |tier| tier.is_a?(Hash) && @reader.valid_id?(tier['id']) && tier['points'].is_a?(Integer) }

    tiers.each do |tier|
      SquareLoyaltyRewardTier.find_or_initialize_by(external_id: tier['id']).update!(program: program, name: string(tier['name']),
        points: tier['points'], pricing_rule_object_id: string(tier.dig('pricing_rule_reference', 'object_id')),
        source_created_at: @reader.timestamp(tier['created_at']), source_present: true, last_seen_at: now)
    end
    SquareLoyaltyRewardTier.where.not(external_id: tiers.map { |tier| tier['id'] }).where(source_present: true).update_all(source_present: false, updated_at: now)
  end

  def publish_promotions(program, rows, now)
    rows.each do |row|
      incentive = row['incentive'].is_a?(Hash) ? row['incentive'] : {}
      minimum = row['minimum_spend_amount_money'].is_a?(Hash) ? row['minimum_spend_amount_money'] : {}
      SquareLoyaltyPromotion.find_or_initialize_by(external_id: row['id']).update!(program: program, name: string(row['name']),
        status: string(row['status']), incentive_type: string(incentive['type']),
        points_multiplier: integer(incentive.dig('points_multiplier_data', 'points_multiplier')),
        points_addition: integer(incentive.dig('points_addition_data', 'points_addition')),
        minimum_spend_cents: integer(minimum['amount']), currency: string(minimum['currency']),
        available_time: json_or_nil(row['available_time']), trigger_limit: json_or_nil(row['trigger_limit']),
        qualifying_item_variation_ids: json_or_nil(row['qualifying_item_variation_ids']), qualifying_category_ids: json_or_nil(row['qualifying_category_ids']),
        source_created_at: @reader.timestamp(row['created_at']), source_updated_at: @reader.timestamp(row['updated_at']),
        canceled_at: @reader.timestamp(row['canceled_at']), last_seen_at: now)
    end
  end

  def normalize_account(row)
    balance = row['balance'] || 0
    lifetime = row['lifetime_points'] || 0
    unless balance.is_a?(Integer) && lifetime.is_a?(Integer) && @reader.valid_id?(row['program_id']) && (row['customer_id'].nil? || @reader.valid_id?(row['customer_id']))
      raise Error, 'Square returned an unreadable loyalty member. Previous loyalty data was kept.'
    end

    deadlines = Array(row['expiring_point_deadlines']).select { |entry| entry.is_a?(Hash) && entry['points'].is_a?(Integer) }
                                                      .map { |entry| { 'points' => entry['points'], 'expires_at' => string(entry['expires_at']) } }
    { external_id: row['id'], program_external_id: row['program_id'], square_customer_id: row['customer_id'], balance: balance,
      lifetime_points: lifetime, phone_number: string(row.dig('mapping', 'phone_number')), expiring_point_deadlines: JSON.generate(deadlines),
      enrolled_at: @reader.timestamp(row['enrolled_at']), source_created_at: @reader.timestamp(row['created_at']),
      source_updated_at: @reader.timestamp(row['updated_at']) }
  end

  def publish_accounts(accounts, now)
    existing = SquareLoyaltyAccount.where(external_id: accounts.map { |attrs| attrs[:external_id] }).index_by(&:external_id)
    accounts.each do |attrs|
      record = existing[attrs[:external_id]] || SquareLoyaltyAccount.new(external_id: attrs[:external_id])
      record.assign_attributes(attrs.except(:external_id).merge(source_present: true, last_seen_at: now))
      record.save! if record.changed?
    end
    # Absent from Square's complete list: kept for history, marked as no longer a member.
    SquareLoyaltyAccount.where.not(external_id: accounts.map { |attrs| attrs[:external_id] }).where(source_present: true)
                        .update_all(source_present: false, updated_at: now)
    @accounts_seen = accounts.size
  end

  # The ledger: catch up from the newest event down to the last complete read,
  # then continue any older window an earlier run ran out of time on.
  def sync_events
    @state = SquareLoyaltySync.state
    @new_events = 0
    deadline = @reader.deadline_from_now
    through = @reader.timestamp(@state['events_synced_through'])
    windows = Array(@state['pending_windows'])
    catch_up_start = through && (through - OVERLAP)
    outcome, oldest = read_window(catch_up_start, nil, deadline)
    # Out of time: the part not read yet becomes a window for the next run.
    windows << { 'start_at' => catch_up_start&.iso8601, 'end_at' => ((oldest || @started_at) + 1).iso8601 } if outcome == :partial
    through = @started_at

    windows = windows.each_with_object([]) do |window, remaining|
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        remaining << window
        next
      end
      start_at = @reader.timestamp(window['start_at'])
      end_at = @reader.timestamp(window['end_at'])
      outcome, oldest = read_window(start_at, end_at, deadline)
      remaining << { 'start_at' => window['start_at'], 'end_at' => (oldest + 1).iso8601 } if outcome == :partial && oldest
      remaining << window if outcome == :partial && !oldest
    end
    raise Error.new('Too many unfinished Square loyalty history windows. Ask the operator to review the read size.', reason: :limit) if windows.size > MAX_PENDING_WINDOWS

    @state.merge!('events_synced_through' => through.iso8601, 'pending_windows' => windows)
    { new_events: @new_events, history_complete: windows.empty?, stored_events: SquareLoyaltyEvent.count }
  end

  def read_window(start_at, end_at, deadline)
    @reader.each_event_page(start_at: start_at, end_at: end_at, deadline: deadline) { |page| store_events(page) }
  end

  def store_events(page)
    rows = page.filter_map { |row| normalize_event(row) }
    return if rows.empty?

    SquareLoyaltyEvent.transaction do
      lock_and_verify!
      now = Time.current
      known = SquareLoyaltyEvent.where(external_id: rows.map { |row| row[:external_id] }).pluck(:external_id).to_set
      fresh = rows.reject { |row| known.include?(row[:external_id]) }.uniq { |row| row[:external_id] }
      SquareLoyaltyEvent.where(external_id: known.to_a).update_all(last_seen_at: now) if known.any?
      if fresh.any?
        SquareLoyaltyEvent.insert_all!(fresh.map { |row| row.merge(tenant_id: Current.tenant_id, last_seen_at: now, created_at: now, updated_at: now) })
        @new_events += fresh.size
      end
    end
  end

  def normalize_event(row)
    type = row['type']
    at = @reader.timestamp(row['created_at'])
    unless SquareLoyaltyEvent::TYPES.include?(type) && at && @reader.valid_id?(row['loyalty_account_id'])
      raise Error, 'Square returned an unreadable loyalty event. Previous loyalty data was kept.'
    end

    detail = row[type == 'OTHER' ? 'other_event' : type.downcase]
    detail = {} unless detail.is_a?(Hash)
    points = detail['points'].is_a?(Integer) ? detail['points'] : nil
    { external_id: row['id'], loyalty_account_external_id: row['loyalty_account_id'], event_type: type, points: points,
      points_change: SquareLoyaltyEvent.points_change(type, points), order_id: id_or_nil(detail['order_id']),
      reward_id: id_or_nil(detail['reward_id']), promotion_id: id_or_nil(detail['loyalty_promotion_id']),
      reason: string(detail['reason'])&.first(500), location_id: id_or_nil(row['location_id']), source: string(row['source']), occurred_at: at }
  end

  def finish!(stats)
    state = (@state || SquareLoyaltySync.state).merge('last_success_at' => Time.current.iso8601, 'last_failure' => nil, 'last_failure_at' => nil,
      'scope' => @reader.scope_status, 'last_counts' => stats.slice(:members, :new_events, :reward_tiers, :points_outstanding))
    state['merchant_id'] = @reader.merchant_id if @reader.merchant_id.present?
    SquareLoyaltySync.save_state!(state)
    ActivityLogger.log('square_loyalty_synced', details: stats.slice(:members, :new_events, :reward_tiers, :history_complete).to_json)
  end

  def string(value)
    value.is_a?(String) ? value.first(255) : nil
  end

  def integer(value)
    value.is_a?(Integer) ? value : nil
  end

  def id_or_nil(value)
    @reader.valid_id?(value) ? value : nil
  end

  def json_or_nil(value)
    value.nil? ? nil : JSON.generate(value)
  end
end
