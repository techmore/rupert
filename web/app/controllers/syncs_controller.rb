# frozen_string_literal: true

class SyncsController < AuthenticatedController
  def index
    @runs = SyncRun.recent(25)
    @logs = recent_logs
  end

  def create
    SyncJob.perform_later(tenant_id: Current.tenant_id, mode: "manual", actor: Current.user.email)
    redirect_to syncs_path, notice: "Full sync started"
  rescue SyncEngine::AlreadyRunning => e
    redirect_to syncs_path, alert: e.message
  end

  def source
    source = params[:source].to_s
    if %w[shopify square].include?(source)
      SyncJob.perform_later(tenant_id: Current.tenant_id, mode: "manual", source: source, actor: Current.user.email)
      redirect_to syncs_path, notice: "#{source.capitalize} sync started"
    else
      redirect_to syncs_path, alert: "Unknown source"
    end
  end

  private

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
