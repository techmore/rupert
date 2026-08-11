# frozen_string_literal: true

require "csv"

class SyncsController < AuthenticatedController
  before_action :authorize_read, only: :index
  before_action :authorize_write, only: [:create, :source, :import_swipesimple]

  def index
    @runs = SyncRun.recent(25)
    @logs = recent_logs
  end

  def create
    SyncJob.perform_later(tenant_id: Current.tenant_id, mode: "manual", actor: Current.user.email)
    redirect_to(syncs_path, notice: "Full sync started")
  rescue SyncEngine::AlreadyRunning => e
    redirect_to(syncs_path, alert: e.message)
  end

  def source
    source = params[:source].to_s
    if ["shopify", "square"].include?(source)
      SyncJob.perform_later(tenant_id: Current.tenant_id, mode: "manual", source: source, actor: Current.user.email)
      redirect_to(syncs_path, notice: "#{source.capitalize} sync started")
    else
      redirect_to(syncs_path, alert: "Unknown source")
    end
  end

  # POST /syncs/import_swipesimple — upload (or paste) a SwipeSimple CSV export.
  def import_swipesimple
    csv = if params[:file].present?
      params[:file].read
    elsif params[:text].present?
      params[:text]
    end
    raise ArgumentError, "Attach a CSV file or paste the export text." if csv.blank?

    summary = SyncEngine.import_swipesimple_csv!(csv, actor: Current.user.email)
    notice = "Imported #{summary.orders} order(s), #{summary.lines} line(s) from SwipeSimple."
    notice += " #{summary.skipped_rows} blank row(s) skipped." if summary.skipped_rows.positive?
    redirect_to(syncs_path, notice: notice)
  rescue ArgumentError, CSV::MalformedCSVError => e
    redirect_to(syncs_path, alert: e.message)
  end

  private

  def authorize_read
    authorize(:module, :sync_read?)
  end

  def authorize_write
    authorize(:module, :sync_write?)
  end

  def recent_logs
    path = Rails.root.join("..", "sync-log.jsonl")
    return [] unless File.exist?(path)

    File.readlines(path).last(40).filter_map do |line|
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end.reverse
  end
end
