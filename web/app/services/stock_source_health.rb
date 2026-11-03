# frozen_string_literal: true

# Stock freshness per platform for the Sync page: the source badge, every
# active store's latest stock read and the most recent problem with what to do
# about it. Reads stored rows only; never contacts a platform.
class StockSourceHealth
  KEYS = %w[shopify ctrax square].freeze
  PURPOSE = { 'shopify' => 'Online sales & stock', 'ctrax' => 'Retail stock (count reference)', 'square' => 'POS sales & stock' }.freeze
  # A failure older than this that has since recovered is no longer shown.
  REMEMBER_FOR = 1.day

  Read = Struct.new(:name, :at, keyword_init: true) do
    def old? = at.nil? || at < SourceSyncStatus::FRESH_FOR.ago
  end
  Problem = Struct.new(:at, :title, :fix, :recovered, keyword_init: true)
  Source = Struct.new(:key, :label, :badge, :ready, :purpose, :reads, :problem, keyword_init: true)

  def self.all = new.all

  def all
    statuses = SourceSyncStatus.all(include_platform: false).index_by { |source| source[:key] }
    KEYS.filter_map do |key|
      status = statuses[key] or next
      Source.new(key: key, label: status[:label], badge: status[:badge], ready: status[:ready], purpose: PURPOSE.fetch(key),
        reads: reads(key).sort_by { |read| read.at || Time.at(0) }, problem: problem(key))
    end
  end

  private

  def reads(key)
    case key
    when 'shopify' then snapshot_reads(ShopifyStockSnapshot)
    when 'ctrax' then snapshot_reads(CtraxStockSnapshot)
    when 'square'
      latest = InventoryLevel.where(source: 'square').group(:locationId).maximum(:updatedAt)
      Location.where(id: latest.keys, active: true).map { |location| Read.new(name: location.name, at: latest[location.id]) }
    end
  end

  def snapshot_reads(model)
    model.includes(:location).select(:id, :location_id, :captured_at).to_a.select { |snapshot| snapshot.location&.active }
      .map { |snapshot| Read.new(name: snapshot.location.name, at: snapshot.captured_at) }
  end

  def problem(key)
    case key
    when 'shopify'
      failure = SyncRun.where(source: %w[all shopify], status: 'failed').order(startedAt: :desc).first
      ok = SyncRun.where(source: %w[all shopify], status: 'success').maximum(:startedAt)
      build(failure&.startedAt, ok) { ['Sync failed', failure.error.presence || 'No message was recorded. Check the run below.'] }
    when 'ctrax'
      failure = SyncAttempt.where(source: 'ctrax', operation: 'stock', status: 'failed').order(queued_at: :desc).first
      ok = SyncAttempt.where(source: 'ctrax', operation: 'stock', status: 'succeeded').maximum(:finished_at)
      build(failure && (failure.finished_at || failure.queued_at), ok) do
        SyncFailure::GUIDANCE.fetch(failure.error_category.to_s) { SyncFailure::GUIDANCE.fetch('unknown') }
      end
    end
  end

  def build(failed_at, ok_at)
    return unless failed_at

    recovered = ok_at.present? && ok_at > failed_at
    return if recovered && failed_at < REMEMBER_FOR.ago

    title, fix = yield
    Problem.new(at: failed_at, title: title, fix: fix, recovered: recovered)
  end
end
