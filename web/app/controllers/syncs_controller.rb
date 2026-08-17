# frozen_string_literal: true

require "csv"

class SyncsController < AuthenticatedController
  before_action :authorize_read, only: :index
  before_action :authorize_write, only: [:create, :source, :import_swipesimple]
  before_action :authorize_push_approve, only: :push_guard_approve
  before_action :authorize_push_freeze, only: [:push_guard_freeze, :push_guard_unfreeze]

  def index
    @runs = SyncRun.recent(25)
    @recent_movements = InventoryMovement.includes(:sync_run).order(createdAt: :desc).limit(12)
    @push_guard = PlatformPushGuard.status_all
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

  # POST /syncs/push_guard_approve — the acting user records an explicit
  # approval toward opening a push window for a platform.
  def push_guard_approve
    platform = params[:platform].to_s
    result = PlatformPushGuard.approve!(platform, email: Current.user.email)
    if result[:window_open]
      expires = result[:window_expires_at]
      redirect_to(syncs_path,
        notice: "Push window for #{PlatformPushGuard.label(platform)} is OPEN (#{result[:approved_by]}/#{result[:needed]} approvals) until #{I18n.l(Time.zone.parse(expires), format: :short)}.")
    else
      redirect_to(syncs_path,
        notice: "Approval recorded for #{PlatformPushGuard.label(platform)} — #{result[:approved_by]} of #{result[:needed]} approvals still needed before writes unlock.")
    end
  rescue PlatformPushGuard::LockedError => e
    redirect_to(syncs_path, alert: e.message)
  rescue ArgumentError => e
    redirect_to(syncs_path, alert: e.message)
  end

  # POST /syncs/push_guard_freeze — hard block on all pushes to a platform
  # (maintenance/update mode), overriding any open approval window.
  def push_guard_freeze
    platform = params[:platform].to_s
    reason = params[:reason].to_s.presence || "maintenance"
    PlatformPushGuard.freeze!(platform, reason: reason, actor: Current.user.email)
    redirect_to(syncs_path, notice: "#{PlatformPushGuard.label(platform)} pushes are now FROZEN — no writes or syncs will run against it until unfrozen.")
  rescue ArgumentError => e
    redirect_to(syncs_path, alert: e.message)
  end

  # POST /syncs/push_guard_unfreeze — lift a maintenance freeze (writes still
  # require an open approval window).
  def push_guard_unfreeze
    platform = params[:platform].to_s
    PlatformPushGuard.unfreeze!(platform, actor: Current.user.email)
    redirect_to(syncs_path, notice: "#{PlatformPushGuard.label(platform)} is unfrozen. Pushes still need an approved window to run.")
  rescue ArgumentError => e
    redirect_to(syncs_path, alert: e.message)
  end

  private

  def authorize_read
    authorize(:module, :sync_read?)
  end

  def authorize_write
    authorize(:module, :sync_write?)
  end

  def authorize_push_approve
    authorize(:module, :reconcile_write?)
  end

  def authorize_push_freeze
    authorize(:module, :settings_write?)
  end
end
