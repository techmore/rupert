# frozen_string_literal: true

# Sell → Compliance (F70): the store's approved register catalog, COA coverage,
# the compliance audit trail and the daily exception report.
class ComplianceController < AuthenticatedController
  include ComplianceAccess

  TABS = %w[catalog certificates categories audit exceptions].freeze
  PAGE_SIZE = 50
  FILTERS = %w[approved unapproved all].freeze

  before_action :require_compliance_viewer!

  def index
    @tab = TABS.include?(params[:tab]) ? params[:tab] : 'catalog'
    @snapshots = CtraxStockSnapshot.includes(:location).order(:location_id).to_a
    @location = Location.find_by(id: params[:location_id]) if params[:location_id].present?
    @location ||= @snapshots.first&.location || ComplianceCatalogItem.first&.location
    @policy = CompliancePolicy.for(@location)
    @categories = ComplianceCategory.ordered.to_a
    @approvers = Compliance::SaleGate.approvers
    send("load_#{@tab}")
  end

  private

  def items_scope
    ComplianceCatalogItem.includes(:compliance_category, :certificates_of_analysis).where(location_id: @location&.id)
  end

  def load_catalog
    @snapshot = @snapshots.find { |snapshot| snapshot.location_id == @location&.id }
    items = items_scope.index_by(&:source_variant_id)
    @filter = FILTERS.include?(params[:filter]) ? params[:filter] : (items.any? ? 'approved' : 'unapproved')
    @query = params[:q].to_s.strip.first(120)
    records = (@snapshot&.records || []).map { |record| [record, items[record['id'].to_s]] }
    # Approved items whose variant left the store's snapshot still show.
    seen = records.to_set { |record, _| record['id'].to_s }
    records += items.values.reject { |item| seen.include?(item.source_variant_id) }.map { |item| [nil, item] }
    records = records.select { |_, item| item } if @filter == 'approved'
    records = records.reject { |_, item| item } if @filter == 'unapproved'
    if @query.present?
      term = @query.downcase
      records = records.select do |record, item|
        [record&.dig('name'), record&.dig('product_name'), record&.dig('sku'), record&.dig('barcode'), item&.compliant_name].any? { |v| v.to_s.downcase.include?(term) }
      end
    end
    records = records.sort_by { |record, item| [item ? 0 : 1, (item&.compliant_name || record&.dig('name')).to_s.downcase] }
    @total = records.size
    @page = [params[:page].to_i, 1].max
    @rows = records.slice((@page - 1) * PAGE_SIZE, PAGE_SIZE) || []
    @counts = { approved: items.size, card: items.values.count { |i| i.approved? && i.card_eligible && i.compliance_category.card_eligible }, suspended: items.values.count { |i| !i.approved? } }
    @drift = @location ? Compliance::Catalog.drift(@location, snapshot: @snapshot) : []
  end

  def load_certificates
    today = Date.current
    @items = items_scope.approved.ordered.to_a.sort_by { |item| [coa_attention(item, today), item.compliant_name.downcase] }
  end

  # Missing first, then expiring within 30 days, then current, then not required.
  def coa_attention(item, today)
    return 3 unless item.coa_required

    coa = item.current_coa(on: today, max_age_days: @policy.coa_max_age_days)
    return 0 unless coa

    coa.current_until(max_age_days: @policy.coa_max_age_days) < today + 30 ? 1 : 2
  end

  def load_categories; end

  def load_audit
    @action_filter = ComplianceEvent::ACTIONS.include?(params[:event_action]) ? params[:event_action] : nil
    scope = ComplianceEvent.recent
    scope = scope.where(action: @action_filter) if @action_filter
    @pagy, @events = pagy(:offset, scope, limit: PAGE_SIZE)
  end

  def load_exceptions
    @day = begin
      Date.iso8601(params[:date].to_s)
    rescue ArgumentError
      Date.current
    end
    window = @day.in_time_zone.all_day
    @events = ComplianceEvent.exceptions.where(created_at: window).recent.to_a
    week = (@day - 6).in_time_zone.beginning_of_day..window.end
    @week_counts = ComplianceEvent.exceptions.where(created_at: week).group(:action).count
    @flagged_card_sales = flagged_card_sales(window)
  end

  # Card sales that went through on an override, or on a cash-only/warned item.
  def flagged_card_sales(window)
    checkouts = PosCheckout.where(paid_at: window, status: 'paid').where.not(tender: 'cash').where.not(compliance_override_by_id: nil).to_a
    sales = PosEventSale.where(occurred_at: window, tender: 'card_terminal').where('override_by_id IS NOT NULL OR flags_json IS NOT NULL').includes(:pos_event).to_a
    { checkouts: checkouts, sales: sales }
  end
end
