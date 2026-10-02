# frozen_string_literal: true

class LedgerController < AuthenticatedController
  before_action :authorize_read

  def index
    @source = params[:source].presence || 'all'
    @window_days = params[:window].present? ? params[:window].to_i.clamp(1, 365) : 30

    since = Time.current - @window_days.days
    scope = LedgerEntry.since(since).by_source(@source)

    # Ledger rows change only when the sync imports orders — cache behind the
    # DataCache version (200 rows rendered per page was ~70ms of ERB alone).
    @entries = DataCache.fetch("ledger/entries/#{@source}/#{@window_days}") { scope.recent(200).to_a }
    @groups = DataCache.fetch("ledger/groups/#{@source}/#{@window_days}") do
      LedgerEntry.since(since).by_source(@source)
                 .group(:source).pluck(:source, Arel.sql('SUM("grossCents") AS gross'), Arel.sql('COUNT(*) AS count'))
    end
    @total_cents = @groups.sum { |_, gross, _| gross.to_i }
  end

  private

  def authorize_read
    authorize(:module, :ledger_read?)
  end
end
