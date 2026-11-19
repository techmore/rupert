# frozen_string_literal: true

# F69: each card processor's approved list of SKUs and categories. Same
# permissions as checkout setup. Every change is audited.
class ProcessorCatalogsController < AuthenticatedController
  MAX_BULK_LINES = 500
  COVERAGE_LIMIT = 2_000

  before_action do
    raise Pundit::NotAuthorizedError unless Current.user.can?('settings.write') && Current.user.can?('sales.write') && Current.user.can?('inventory.write')
    skip_authorization # gate: settings.write + sales.write + inventory.write, as checkout setup
    response.headers['Cache-Control'] = 'no-store'
  end
  before_action :load_catalog, except: :index

  def index
    existing = ProcessorCatalog.includes(:entries, :approved_by).index_by(&:processor)
    @catalogs = ProcessorCatalog::PROCESSORS.keys.map { |key| existing[key] || ProcessorCatalog.new(processor: key) }
    @items = catalog_items
    @coverage = @catalogs.select(&:enforced).to_h do |catalog|
      result = Payments::ItemEligibility.check(processor: catalog.processor, items: @items)
      [catalog.processor, result.blocked]
    end
  end

  def update
    fields = params.require(:processor_catalog).permit(:enforced, :approval_reference, :approval_note, :lock_version)
    was_enforced = @catalog.enforced
    @catalog.assign_attributes(fields)
    if @catalog.will_save_change_to_approval_reference? || (@catalog.enforced && !was_enforced)
      @catalog.approved_by = Current.user
      @catalog.approved_at = Time.current
    end
    if @catalog.save
      ActivityLogger.log('processor_catalog_saved', subject: @catalog,
        details: "#{@catalog.label}: #{@catalog.enforced ? 'enforced' : 'not enforced'}; approval #{@catalog.approval_reference.presence || 'none'}".truncate(500))
      redirect_to processor_catalogs_path(anchor: @catalog.processor), notice: "#{@catalog.label} approval saved."
    else
      redirect_to processor_catalogs_path(anchor: @catalog.processor), alert: @catalog.errors.full_messages.to_sentence
    end
  rescue ActiveRecord::StaleObjectError
    redirect_to processor_catalogs_path, alert: 'This approval changed. Reload before saving.'
  end

  def add_entries
    kind = params[:kind].to_s
    raise ArgumentError, 'Choose approved SKU, approved category or excluded SKU.' unless ProcessorCatalogEntry::KINDS.key?(kind)
    values = params[:values].to_s.split(/\r?\n|,/).map(&:squish).compact_blank.uniq
    raise ArgumentError, 'Enter at least one value.' if values.empty?
    raise ArgumentError, "Add at most #{MAX_BULK_LINES} values at a time." if values.size > MAX_BULK_LINES

    added = 0
    ProcessorCatalog.transaction do
      @catalog.save! if @catalog.new_record?
      @catalog.lock!
      values.each do |value|
        normalized = ProcessorCatalogEntry.normalize(kind, value)
        next if @catalog.entries.exists?(kind: kind, normalized_value: normalized)

        @catalog.entries.create!(kind: kind, value: value, added_by: Current.user)
        added += 1
      end
    end
    ActivityLogger.log('processor_catalog_entries_added', subject: @catalog,
      details: "#{@catalog.label} #{ProcessorCatalogEntry::KINDS[kind]}: #{values.first(20).join(', ')}#{' …' if values.size > 20}".truncate(1000))
    redirect_to processor_catalogs_path(anchor: @catalog.processor), notice: "#{added} added to the #{@catalog.label} list#{" (#{values.size - added} already listed)" if added < values.size}."
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    message = e.is_a?(ActiveRecord::RecordInvalid) ? e.record.errors.full_messages.to_sentence : e.message
    redirect_to processor_catalogs_path(anchor: @catalog.processor), alert: message
  end

  def remove_entry
    entry = @catalog.entries.find(params[:id])
    ProcessorCatalog.transaction do
      @catalog.lock!
      entry.delete
    end
    ActivityLogger.log('processor_catalog_entry_removed', subject: @catalog,
      details: "#{@catalog.label} #{ProcessorCatalogEntry::KINDS[entry.kind]}: #{entry.value}".truncate(500))
    redirect_to processor_catalogs_path(anchor: @catalog.processor), notice: "Removed #{entry.value} from the #{@catalog.label} list."
  end

  private

  def load_catalog
    processor = params[:processor].to_s
    raise ActiveRecord::RecordNotFound unless ProcessorCatalog::PROCESSORS.key?(processor)

    @catalog = ProcessorCatalog.find_or_initialize_by(processor: processor)
  end

  # Current POS catalog (C-Trax store snapshots), one row per native variant, so
  # the page can show which products an enforced list would refuse.
  def catalog_items
    rows = {}
    CtraxStockSnapshot.where(location_id: Location.where(source: 'ctrax').select(:id)).find_each do |snapshot|
      snapshot.records.each do |record|
        break if rows.size >= COVERAGE_LIMIT
        next if record['listed'] == false

        rows[record['id'].to_s] ||= { 'variant_id' => record['id'].to_s, 'sku' => record['sku'], 'category' => record['category'], 'name' => record['name'] }
      end
    end
    rows.values.sort_by { |row| row['name'].to_s }
  end
end
