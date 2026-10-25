# frozen_string_literal: true

# Settings → Backups (#421): the key that encrypts backups, and the owner's recovery kit.
#
# "Create backup key" makes an age key pair in memory, stores ONLY the public half (BackupEncryptionKey) and answers
# with the recovery kit PDF holding the private half and the Active Record encryption keys. The private key is not
# saved, logged, cached or shown again: losing the kit means losing access to the backups made with it.
#
# The new key starts pending. Typing the check code printed on the kit activates it, so no backup is ever encrypted to
# a key whose kit was not saved. Until then the previous key (if any) keeps being used.
#
# Super admins with settings.write only: the kit decrypts every customer's data in this instance. Creating a kit also
# needs a fresh sign-in (REAUTH_WINDOW) and an explicit acknowledgement.
class BackupKeysController < AuthenticatedController
  REAUTH_WINDOW = 15.minutes
  REAUTH_METHODS = %w[password google].freeze

  before_action :no_store
  before_action :authorize_owner
  rate_limit to: 10, within: 10.minutes, only: :activate,
    with: -> { redirect_to(settings_backups_path, alert: 'Too many check code attempts. Wait ten minutes and try again.') }

  def show
    @current = BackupEncryptionKey.current
    @pending = pending_key
    @keys = BackupEncryptionKey.newest_first.limit(20)
    @recent_sign_in = recent_sign_in?
    @password_session = session[:auth_method] == 'password'
    @workspace = workspace_name
  end

  # POST /settings/backups/key → the recovery kit PDF (once).
  def create
    unless params[:acknowledge] == '1'
      return redirect_to(settings_backups_path, alert: 'Tick the box to confirm you will store the recovery kit before creating a key.')
    end
    unless reauthenticated?
      ActivityLogger.log('backup_key_create_denied', details: 'Fresh sign-in required')
      return redirect_to(settings_backups_path, alert: 'Sign in again (or enter your password) before creating a backup key.')
    end

    pair = BackupEncryption::AgeKey.generate
    code = BackupEncryptionKey.new_check_code
    key = BackupEncryptionKey.transaction do
      # Earlier unconfirmed keys never protected a backup; a new kit replaces them.
      BackupEncryptionKey.where(activated_at: nil, retired_at: nil).delete_all
      BackupEncryptionKey.create!(recipient: pair.recipient, confirmation_digest: BackupEncryptionKey.digest(code),
        created_by_id: Current.user.id)
    end
    kit = BackupEncryption::RecoveryKitPdf.new(identity: pair.identity, key: key, check_code: code,
      workspace: workspace_name, created_by: Current.user.display_name.presence || Current.user.email)
    ActivityLogger.log('backup_key_created', subject: key, label: key.fingerprint,
      details: "Backup key #{key.fingerprint} created; recovery kit downloaded once. Waiting for its check code.")
    send_data(kit.render, filename: kit.filename, type: 'application/pdf', disposition: 'attachment')
  end

  # POST /settings/backups/key/activate — the check code from the kit makes the pending key the one backups use.
  def activate
    key = pending_key
    if key.nil?
      return redirect_to(settings_backups_path, alert: 'No backup key is waiting for its check code. Create a new key.')
    end
    unless key.code_matches?(params[:check_code])
      ActivityLogger.log('backup_key_activation_failed', subject: key, label: key.fingerprint, details: 'Wrong check code')
      return redirect_to(settings_backups_path, alert: 'That check code does not match the newest recovery kit.')
    end

    previous = BackupEncryptionKey.current
    key.activate!(actor: Current.user)
    ActivityLogger.log('backup_key_activated', subject: key, label: key.fingerprint,
      details: ["Backups now encrypt to #{key.fingerprint}", ("#{previous.fingerprint} retired; its kit still opens older backups" if previous)].compact.join('. '))
    redirect_to(settings_backups_path, notice: "Backup key #{key.fingerprint} is active. The next backup is encrypted with it.")
  end

  private

  def pending_key
    BackupEncryptionKey.where(activated_at: nil, retired_at: nil).newest_first.detect { |key| !key.expired? }
  end

  def workspace_name
    TenantSettings.business_name.presence || Current.tenant&.name.presence || 'Rupert'
  rescue StandardError
    Current.tenant&.name.presence || 'Rupert'
  end

  def recent_sign_in?
    REAUTH_METHODS.include?(session[:auth_method]) && session[:authenticated_at].to_i >= REAUTH_WINDOW.ago.to_i
  end

  def reauthenticated?
    return true if recent_sign_in?

    session[:auth_method] == 'password' && params[:password].present? && Current.user.authenticate(params[:password].to_s).present?
  end

  def authorize_owner
    actor = User.find_by(id: Current.user&.id, active: true)
    return if actor&.super_admin? && actor.can?('settings.write')

    ActivityLogger.log('backup_key_access_denied', details: "#{action_name} refused")
    redirect_to(settings_path, alert: 'Only the instance owner (super admin) can manage backup keys.')
  end

  def no_store
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Pragma'] = 'no-cache'
  end
end
