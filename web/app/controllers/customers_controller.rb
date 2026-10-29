# frozen_string_literal: true

require 'csv'

class CustomersController < AuthenticatedController
  LAST_ORDER_SQL = '(SELECT MAX(orders.occurred_at) FROM orders WHERE orders.customer_id = customers.id)'
  SPEND_SQL = '(SELECT COALESCE(SUM(orders.gross_cents), 0) FROM orders WHERE orders.customer_id = customers.id)'
  ORDER_COUNT_SQL = '(SELECT COUNT(*) FROM orders WHERE orders.customer_id = customers.id)'
  OWNER_NAME_SQL = "(SELECT LOWER(COALESCE(NULLIF(TRIM(users.name), ''), users.email)) FROM users WHERE users.id = customers.owner_id)"
  UNKNOWN_LAST_SQL = "CASE WHEN #{Core::Customer::UNKNOWN_SQL} THEN 1 ELSE 0 END".freeze
  NO_EMAIL_LAST_SQL = "CASE WHEN COALESCE(TRIM(customers.email), '') = '' THEN 1 ELSE 0 END"
  STAGE_SQL = "CASE customers.crm_status #{Core::Customer::CRM_STATUSES.each_with_index.map { |status, i| "WHEN '#{status}' THEN #{i}" }.join(' ')} ELSE #{Core::Customer::CRM_STATUSES.size} END".freeze
  # The CRM list's sortable headings (ListSort). Blank names, emails, owners
  # and never-ordered customers sort last in both directions. `dir` is only
  # ever :asc or :desc, so the SQL fragments below are fixed text.
  SORT_COLUMNS = {
    'name' => ListSort.column('Name') { |dir| [Arel.sql(UNKNOWN_LAST_SQL), { last_name: dir, first_name: dir, id: dir }] },
    'email' => ListSort.column('Contact') { |dir| [Arel.sql(NO_EMAIL_LAST_SQL), Arel.sql("LOWER(customers.email) #{dir.upcase}"), { id: dir }] },
    'status' => ListSort.column('Relationship', phrases: { 'asc' => 'lead first', 'desc' => 'inactive first' }) { |dir| [Arel.sql("#{STAGE_SQL} #{dir.upcase}"), { id: dir }] },
    'owner' => ListSort.column('Owner') { |dir| [Arel.sql('customers.owner_id IS NULL'), Arel.sql("#{OWNER_NAME_SQL} #{dir.upcase}"), { id: dir }] },
    'source' => ListSort.column('Source') { |dir| { source: dir, id: dir } },
    'orders' => ListSort.column('Orders', :number) { |dir| [Arel.sql("#{ORDER_COUNT_SQL} #{dir.upcase}"), { id: dir }] },
    'last_order' => ListSort.column('Last order', :date) { |dir| [Arel.sql("#{LAST_ORDER_SQL} IS NULL"), Arel.sql("#{LAST_ORDER_SQL} #{dir.upcase}"), { id: dir }] },
    'lifetime' => ListSort.column('Lifetime', :number) { |dir| [Arel.sql("#{SPEND_SQL} #{dir.upcase}"), { id: dir }] },
    'created' => ListSort.column('Added', :date) { |dir| { created_at: dir, id: dir } }
  }.freeze
  SORT_DEFAULT = %w[created desc].freeze
  # Older one-word sort links and bookmarks.
  SORT_ALIASES = {
    'recent' => %w[created desc], 'oldest' => %w[created asc], 'spend' => %w[lifetime desc], 'last_order' => %w[last_order desc]
  }.freeze
  NAME_FILTERS = { 'unknown' => 'Unknown (no name)', 'named' => 'Named' }.freeze

  before_action :set_customer, only: %i[show edit update]

  def index
    authorize(:module, :customers_read?)

    @directory_states = DirectorySyncState.where(kind: 'customers').index_by(&:provider)
    @q = filtered_customers.ransack(params[:q])
    @due_follow_ups = CustomerFollowUp.due.includes(:customer, :owner).order(:due_on, :id).limit(20)
    @due_count = CustomerFollowUp.due.count
    @owners = crm_owners
    @sort = ListSort.new(SORT_COLUMNS, sort: params[:sort], dir: params[:dir], default: SORT_DEFAULT, aliases: SORT_ALIASES)
    # Ordered outside the DISTINCT search, so the order and spend sorts work on every database.
    matching = Core::Customer.where(id: @q.result.select(:id)).includes(:owner)
    @pagy, @customers = pagy(:offset, @sort.apply(matching), limit: 25)
    @unknown_count = Core::Customer.unknown.count
    @status_counts = Core::Customer.group(:crm_status).count
    @total_customers = @status_counts.values.sum
    @filtered = filters_active?
    # One grouped SUM + one grouped COUNT for the page instead of a lifetime-
    # value query and an orders COUNT per row (the view calls orders.size).
    ids = @customers.map(&:id)
    @lifetime_totals = Core::Order.where(customer_id: ids).group(:customer_id, :currency).sum(:gross_cents)
    @order_counts = Core::Order.where(customer_id: ids).group(:customer_id).count
    @last_orders = Core::Order.where(customer_id: ids).group(:customer_id).maximum(:occurred_at)
  end

  def sync_directory
    authorize(:module, :customers_write?)
    authorize(:module, :sync_write?)
    Directories::Sync::PAIRS.each do |provider, kinds|
      next unless kinds.include?('customers') && Directories::Sync.available?(provider)

      DirectorySyncJob.perform_later(Current.tenant_id, provider, 'customers', manual: true)
    end
    redirect_to(customers_path, notice: 'Customer directory sync queued. Refresh to see the latest read status.')
  end

  def show
    authorize(@customer)
    @directory_states = DirectorySyncState.where(kind: 'customers').index_by(&:provider)
    @last_order_at = @customer.orders.maximum(:occurred_at)
    @open_follow_up_count = @customer.follow_ups.open.count
    @overdue_follow_up_count = @customer.follow_ups.due.where(due_on: ...Date.current).count
    @pagy, @orders = pagy(:offset, @customer.orders.order(occurred_at: :desc, id: :desc), limit: 25)
    @interactions_pagy, @interactions = pagy(:offset, @customer.interactions.includes(:author).order(created_at: :desc, id: :desc), limit: 25, page_key: 'activity_page')
    @follow_ups_pagy, @follow_ups = pagy(:offset, @customer.follow_ups.includes(:owner).order(Arel.sql('CASE WHEN completed_at IS NULL THEN 0 ELSE 1 END'), :due_on, :id), limit: 25, page_key: 'follow_up_page')
    @owners = crm_owners
  end

  def new
    authorize(:module, :customers_write?)
    @customer = Core::Customer.new(source: 'manual')
    @owners = crm_owners
  end

  def create
    authorize(:module, :customers_write?)
    @owners = crm_owners
    @customer = Core::Customer.new(customer_params)
    @customer.source = 'manual'
    @customer.external_id = "manual:#{SecureRandom.hex(8)}"

    if @customer.save
      log_customer('customer_created', 'manual profile')
      redirect_to(customer_path(@customer), notice: 'Customer added.')
    else
      render(:new, status: :unprocessable_entity)
    end
  end

  def edit
    authorize(@customer)
    @owners = crm_owners
  end

  def update
    authorize(@customer)
    @owners = crm_owners
    if @customer.update(customer_params)
      changed = @customer.previous_changes.keys.excluding('updated_at')
      log_customer('customer_updated', "fields: #{changed.join(', ')}") if changed.any?
      redirect_to(customer_path(@customer), notice: 'Customer updated.')
    else
      render(:edit, status: :unprocessable_entity)
    end
  end

  def export
    authorize(:module, :customers_write?)
    records = filtered_customers.ransack(params[:q]).result.distinct.order(:id)
    total = records.count
    if total > 25_000
      return redirect_to(customers_path, alert: 'Narrow your filters to 25,000 profiles or fewer before exporting.')
    end
    csv = CSV.generate do |rows|
      rows << %w[source external_id first_name last_name preferred_name email phone crm_status tags]
      records.find_each do |customer|
        rows << %i[source external_id first_name last_name preferred_name email phone crm_status tags].map do |key|
          value = customer.public_send(key).to_s
          value.match?(/\A[\s]*[=+@-]/) ? "'#{value}" : value
        end
      end
    end
    log_export('Customers CSV', export_summary(total))
    response.headers['Cache-Control'] = 'no-store'
    send_data(csv, filename: "rupert-customers-#{Date.current.iso8601}.csv", type: 'text/csv')
  end

  private

  # Customer entries name the profile by id only: names, emails and phone
  # numbers stay out of the Activity log, and field values are never copied.
  def log_customer(action, details)
    ActivityLogger.log(action, subject: @customer, label: "Customer ##{@customer.id}", details: details)
  end

  # Which filters shaped the export and how many profiles it held; no values
  # from the profiles themselves.
  def export_summary(total)
    filters = %i[status source owner due directory name].filter_map { |key| "#{key}=#{params[key]}" if params[key].present? }
    filters << 'search' if params[:q].respond_to?(:values) && params[:q].values.any?(&:present?)
    [helpers.pluralize(total, 'profile'), filters.join(' ').presence].compact.join(', ')
  end

  # Staff who lack customers.read get an explanation instead of a bare redirect;
  # write-permission denials keep the standard behaviour.
  def user_not_authorized
    return super if Current.user&.can?('customers.read')

    render('customers/no_access', status: :forbidden)
  end

  def filters_active?
    q = params[:q].respond_to?(:values) ? params[:q].values.any?(&:present?) : false
    q || %i[status source owner due directory name].any? { |key| params[key].present? }
  end

  def filtered_customers
    records = Core::Customer.all
    records = records.where(crm_status: params[:status]) if Core::Customer::CRM_STATUSES.include?(params[:status])
    records = records.where(source: params[:source]) if Core::Customer::SOURCES.include?(params[:source])
    records = records.where(owner_id: Current.user.id) if params[:owner] == 'mine'
    records = records.where(owner_id: nil) if params[:owner] == 'unassigned'
    records = records.unknown if params[:name] == 'unknown'
    records = records.named if params[:name] == 'named'
    records = records.where(id: CustomerFollowUp.due.select(:customer_id)) if params[:due] == '1'
    records = records.where(id: verified_customers.select(:id)) if params[:directory] == 'verified'
    records = records.where.not(source: 'manual').where.not(id: verified_customers.select(:id)) if params[:directory] == 'historical'
    records
  end

  def verified_customers
    DirectorySyncState.where(kind: 'customers').where.not(last_success_at: nil).map do |state|
      Core::Customer.where(source: state.provider, source_synced_at: state.last_success_at)
    end.reduce(Core::Customer.none, :or)
  end

  def crm_owners
    User.where(tenant_id: Current.tenant_id).active.ordered.select { |user| user.can?('customers.read') }
  end

  def set_customer
    @customer = Core::Customer.find_by!(tenant_id: Current.tenant_id, id: params[:id])
  end

  def customer_params
    attributes = params.require(:customer).permit(:preferred_name, :crm_status, :tags, :owner_id, :notes)
    if !@customer || @customer.source == 'manual'
      attributes.merge!(params.require(:customer).permit(:first_name, :last_name, :email, :phone))
    end
    attributes
  end
end
