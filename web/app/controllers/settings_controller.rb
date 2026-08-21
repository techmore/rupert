# frozen_string_literal: true

class SettingsController < AuthenticatedController
  before_action :authorize_read, only: [:show, :env, :drive_status, :drive_logs, :backup]
  before_action :authorize_write, except: [:show, :env, :drive_status, :drive_logs, :backup]
  before_action :authorize_super_admin, only: [:backup, :restore, :drive_backup, :env_export]

  def show; end

  # GET /settings/env.json — masked view of managed env keys
  def env
    render(json: {
      keys: EnvStore::MANAGED_KEYS.map do |key|
        value = EnvStore.fetch(key, "")
        {
          key: key,
          set: value.present?,
          masked: value.present? ? EnvStore.mask(value) : nil,
          source: Setting.exists?(key: key, tenant_id: Current.tenant_id) ? "database" : "environment",
        }
      end,
    })
  end

  # POST /settings/env_import — JSON { text: } or multipart .env upload
  def env_import
    text = if params[:text].present?
      params[:text]
    elsif params[:file].present?
      params[:file].read
    end
    raise ArgumentError, "Provide .env text or a file" if text.blank?

    imported = EnvStore.import!(text)
    render(json: { ok: true, imported: imported })
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    render(json: { ok: false, error: e.message }, status: :unprocessable_entity)
  end

  # GET /settings/env_export — raw .env text of managed keys
  def env_export
    body = EnvStore.export.map { |key, value| "#{key}=#{value}" }.join("\n") + "\n"
    render(plain: body, content_type: "text/plain")
  end

  # GET /settings/backup — consistent SQLite snapshot download
  def backup
    path = BackupService.snapshot_path
    send_file(
      path,
      filename: "rupert-backup-#{Time.now.strftime("%Y%m%d-%H%M%S")}.sqlite3",
      type: "application/octet-stream",
    )
  end

  # POST /settings/restore — upload a .sqlite3 backup and swap it in
  def restore
    file = params[:file]
    raise ArgumentError, "No file uploaded" if file.nil?

    path = file.tempfile.path
    BackupService.restore!(path)
    render(json: { ok: true })
  rescue BackupService::RestoreError, ArgumentError => e
    render(json: { ok: false, error: e.message }, status: :unprocessable_entity)
  end

  # GET /settings/drive_status — connection state + last run (JSON)
  def drive_status
    render(json: GoogleDriveBackupService.status)
  end

  # GET /settings/drive_logs — recent backup attempts (JSON)
  def drive_logs
    rows = BackupLog.recent(10).map do |log|
      {
        status: log.status,
        fileName: log.fileName,
        driveUrl: log.driveUrl,
        startedAt: log.startedAt,
        finishedLabel: log.finishedAt&.utc&.strftime("%b %e %H:%M UTC"),
        error: log.error,
      }
    end
    render(json: rows)
  end

  # GET /settings/drive_auth — send the user to Google's consent screen
  def drive_auth
    state = SecureRandom.hex(16)
    session[:drive_oauth_state] = state
    redirect_to(
      GoogleDriveBackupService.auth_url(redirect_uri: drive_oauth_callback_settings_url, state: state),
      allow_other_host: true,
    )
  rescue GoogleDriveBackupService::NotConfiguredError => e
    redirect_to(settings_path, alert: e.message)
  end

  # GET /settings/drive_oauth_callback — exchange the code, store refresh token
  def drive_oauth_callback
    if params[:error].present?
      return redirect_to(settings_path, alert: "Google Drive authorization was declined.")
    end
    if session[:drive_oauth_state].blank? || session[:drive_oauth_state] != params[:state]
      return redirect_to(settings_path, alert: "Google Drive authorization failed state check. Try again.")
    end

    GoogleDriveBackupService.exchange_code!(params[:code], redirect_uri: drive_oauth_callback_settings_url)
    session.delete(:drive_oauth_state)
    redirect_to(settings_path, notice: "Connected to Google Drive.")
  rescue GoogleDriveBackupService::NotConfiguredError,
         GoogleDriveBackupService::NotConnectedError,
         Signet::AuthorizationError => e
    session.delete(:drive_oauth_state)
    redirect_to(settings_path, alert: e.message)
  end

  # POST /settings/drive_backup — run a backup right now
  def drive_backup
    log = GoogleDriveBackupService.backup!(actor: "user")
    render(json: {
      ok: log.success?, status: log.status, fileName: log.fileName, driveUrl: log.driveUrl, error: log.error,
    })
  rescue GoogleDriveBackupService::NotConnectedError => e
    render(json: { ok: false, error: e.message }, status: :unprocessable_entity)
  end

  # POST /settings/drive_disconnect — forget the refresh token
  def drive_disconnect
    GoogleDriveBackupService.disconnect!
    redirect_to(settings_path, notice: "Disconnected from Google Drive.")
  end

  # POST /settings/oauth_credentials — save Google sign-in client id/secret
  def oauth_credentials
    EnvStore.set("GOOGLE_OAUTH_CLIENT_ID", params[:client_id].to_s.strip) if params.key?(:client_id)
    EnvStore.set("GOOGLE_OAUTH_CLIENT_SECRET", params[:client_secret].to_s.strip) if params.key?(:client_secret)
    redirect_to(settings_path, notice: "Google sign-in credentials saved.")
  end

  # POST /settings/oauth_domains — allow a new email domain to sign in
  def oauth_domains
    domain = OauthAllowedDomain.new(domain: params[:domain], tenant_id: Current.tenant_id)
    if domain.save
      redirect_to(settings_path, notice: "Allowed #{domain.domain} to sign in with Google.")
    else
      redirect_to(settings_path, alert: domain.errors.full_messages.to_sentence)
    end
  end

  # DELETE /settings/oauth_domains — revoke a domain from Google sign-in
  def oauth_remove_domain
    domain = OauthAllowedDomain.find_by(tenant_id: Current.tenant_id,
      domain: params[:domain].to_s.downcase.strip.sub(/\A@/, ""))
    if domain&.destroy
      redirect_to(settings_path, notice: "Removed #{domain.domain} from Google sign-in.")
    else
      redirect_to(settings_path, alert: "Domain not found.")
    end
  end

  # POST /settings/tenant — update business settings (name, invoice prefix,
  # low-stock threshold).
  def tenant
    TenantSettings.set(:business_name, params[:business_name]) if params[:business_name].present?
    TenantSettings.set(:invoice_prefix, params[:invoice_prefix]) if params[:invoice_prefix].present?
    if params[:low_stock_threshold].present?
      TenantSettings.set(:low_stock_threshold, params[:low_stock_threshold].to_i)
    end
    redirect_to(settings_path, notice: "Business settings saved.")
  end

  # POST /settings/fulfillment_workflow — enable/disable the office fulfillment
  # status workflow on orders.
  def fulfillment_workflow
    FeatureFlag.set(:fulfillment_workflow, params[:enabled] == "1")
    redirect_to(settings_path, notice: "Fulfillment workflow #{params[:enabled] == "1" ? "enabled" : "disabled"}.")
  end

  # POST /settings/buzz_generate — create (or replace) the Rupert agent keypair
  def buzz_generate
    BuzzAgent.generate_keypair!
    redirect_to(settings_path, notice: "Buzz agent keypair generated — #{BuzzAgent.agent_npub}")
  rescue StandardError => e
    redirect_to(settings_path, alert: "Could not generate keypair: #{e.message}")
  end

  # POST /settings/buzz_register — publish the agent's kind 0 profile so Buzz
  # recognizes the identity and it can be added as a channel member.
  def buzz_register
    ok, message = BuzzAgent.register!
    if ok
      redirect_to settings_path, notice: "Agent profile published to Buzz — #{BuzzAgent.agent_npub}"
    else
      redirect_to settings_path, alert: "Could not publish profile: #{message}"
    end
  end

  # POST /settings/buzz_test — publish a test message to Buzz
  def buzz_test
    ok, message = BuzzAgent.notify("Test message from the Rupert agent (#{Time.current.strftime("%b %e %H:%M")})")
    if ok
      redirect_to(settings_path, notice: "Buzz test sent: #{message}")
    else
      redirect_to(settings_path, alert: "Buzz test failed: #{message}")
    end
  end

  private

  def authorize_read
    authorize(:module, :settings_read?)
  end

  def authorize_write
    authorize(:module, :settings_write?)
  end

  def authorize_super_admin
    redirect_to(settings_path, alert: "Only the super admin can do that.") unless Current.user.super_admin?
  end
end
