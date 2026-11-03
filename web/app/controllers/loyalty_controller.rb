# frozen_string_literal: true

# Loyalty members, points and rewards (read-only mirror of the store's Square
# Loyalty program; see SquareLoyaltyImport). Nothing on this page changes Square.
class LoyaltyController < AuthenticatedController
  CUSTOMER_NAME_SQL = "(SELECT LOWER(COALESCE(NULLIF(TRIM(customers.preferred_name), ''), TRIM(COALESCE(customers.last_name, '') || ' ' || COALESCE(customers.first_name, '')))) " \
                      "FROM customers WHERE customers.tenant_id = square_loyalty_accounts.tenant_id AND customers.source = 'square' " \
                      'AND customers.external_id = square_loyalty_accounts.square_customer_id LIMIT 1)'
  LAST_ACTIVITY_SQL = '(SELECT MAX(square_loyalty_events.occurred_at) FROM square_loyalty_events WHERE square_loyalty_events.tenant_id = square_loyalty_accounts.tenant_id ' \
                      'AND square_loyalty_events.loyalty_account_external_id = square_loyalty_accounts.external_id)'
  SORT_COLUMNS = {
    'member' => ListSort.column('Member') { |dir| [Arel.sql("#{CUSTOMER_NAME_SQL} IS NULL"), Arel.sql("#{CUSTOMER_NAME_SQL} #{dir.upcase}"), { id: dir }] },
    'balance' => ListSort.column('Points', :number) { |dir| { balance: dir, id: dir } },
    'lifetime' => ListSort.column('Lifetime points', :number) { |dir| { lifetime_points: dir, id: dir } },
    'enrolled' => ListSort.column('Enrolled', :date) { |dir| [Arel.sql('square_loyalty_accounts.enrolled_at IS NULL'), { enrolled_at: dir, id: dir }] },
    'activity' => ListSort.column('Last activity', :date) { |dir| [Arel.sql("#{LAST_ACTIVITY_SQL} IS NULL"), Arel.sql("#{LAST_ACTIVITY_SQL} #{dir.upcase}"), { id: dir }] }
  }.freeze
  SORT_DEFAULT = %w[balance desc].freeze
  SHOW = { '' => 'Current members', 'redeemable' => 'Can claim a reward', 'unlinked' => 'Not matched to a customer', 'former' => 'No longer members' }.freeze

  def index
    authorize(:module, :customers_read?)
    @program = SquareLoyaltyProgram.current
    @tiers = @program ? @program.reward_tiers.current.order(:points, :id).to_a : []
    @promotions = @program ? @program.promotions.order(Arel.sql("CASE status WHEN 'ACTIVE' THEN 0 WHEN 'SCHEDULED' THEN 1 ELSE 2 END"), source_created_at: :desc).limit(10).to_a : []
    @state = SquareLoyaltySync.state
    @schedule_enabled = SquareLoyaltySync.enabled?
    @can_sync = Current.user.can?('customers.write') && Current.user.can?('sync.write')

    current = SquareLoyaltyAccount.current
    @member_count = current.count
    @points_outstanding = current.sum(:balance)
    @tier_counts = @tiers.to_h { |tier| [tier.id, current.where(balance: tier.points..).count] }
    since = 30.days.ago
    @earned_30 = SquareLoyaltyEvent.where(occurred_at: since.., event_type: %w[ACCUMULATE_POINTS ACCUMULATE_PROMOTION_POINTS]).sum(:points_change)
    @redeemed_30 = SquareLoyaltyEvent.where(occurred_at: since.., event_type: 'REDEEM_REWARD').count

    @show = SHOW.key?(params[:show].to_s) ? params[:show].to_s : ''
    @query = params[:q].to_s.strip.first(100)
    @sort = ListSort.new(SORT_COLUMNS, sort: params[:sort], dir: params[:dir], default: SORT_DEFAULT)
    @pagy, @accounts = pagy(:offset, @sort.apply(filtered_accounts), limit: 25)
    @customers = SquareLoyaltyAccount.customers_by_square_id(@accounts.map(&:square_customer_id))
    @last_activity = SquareLoyaltyEvent.where(loyalty_account_external_id: @accounts.map(&:external_id)).group(:loyalty_account_external_id).maximum(:occurred_at)
  end

  def sync
    authorize(:module, :customers_write?)
    authorize(:module, :sync_write?)
    return redirect_to(loyalty_path, alert: 'Connect Square first, then sync loyalty.') unless SquareClient.configured?

    SquareLoyaltySyncJob.perform_later(Current.tenant_id, actor_id: Current.user.id)
    redirect_to(loyalty_path, notice: 'Loyalty sync queued. It only reads Square; refresh in a minute to see the result.')
  end

  private

  def filtered_accounts
    records = @show == 'former' ? SquareLoyaltyAccount.where(source_present: false) : SquareLoyaltyAccount.current
    if @show == 'redeemable'
      lowest = @tiers.map(&:points).select(&:positive?).min
      records = lowest ? records.where(balance: lowest..) : records.none
    end
    records = records.where.not(square_customer_id: matched_customer_ids).or(records.where(square_customer_id: nil)) if @show == 'unlinked'
    if @query.present?
      matching = Core::Customer.where(source: 'square').search(@query).select(:external_id)
      records = records.where(square_customer_id: matching)
    end
    records
  end

  def matched_customer_ids
    Core::Customer.where(source: 'square').select(:external_id)
  end
end
