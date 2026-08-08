# frozen_string_literal: true

class LedgerController < AuthenticatedController
  def index
    @source = params[:source].presence || "all"
    @window_days = params[:window].to_i.clamp(1, 365)
    @window_days = 30 if @window_days.zero?

    since = Time.current - @window_days.days
    scope = LedgerEntry.since(since).by_source(@source)

    @entries = scope.recent(200)
    @groups = LedgerEntry.since(since).by_source(@source)
      .group(:source).pluck(:source, Arel.sql("SUM(\"grossCents\") AS gross"), Arel.sql("COUNT(*) AS count"))
    @total_cents = @groups.sum { |_, gross, _| gross.to_i }
  end
end
