# frozen_string_literal: true

class LedgerController < AuthenticatedController
  before_action :authorize_read

  def index
    @source = params[:source].presence || "all"
    @window_days = params[:window].present? ? params[:window].to_i.clamp(1, 365) : 30

    since = Time.current - @window_days.days
    scope = LedgerEntry.since(since).by_source(@source)

    @entries = scope.recent(200)
    @groups = LedgerEntry.since(since).by_source(@source)
      .group(:source).pluck(:source, Arel.sql("SUM(\"grossCents\") AS gross"), Arel.sql("COUNT(*) AS count"))
    @total_cents = @groups.sum { |_, gross, _| gross.to_i }
  end

  private

  def authorize_read
    authorize(:module, :ledger_read?)
  end
end
