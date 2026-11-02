# frozen_string_literal: true

class PosSettingsController < AuthenticatedController
  before_action do
    raise Pundit::NotAuthorizedError unless Current.user.can?('settings.write') && Current.user.can?('sales.write') && Current.user.can?('inventory.write')

    skip_authorization # gate: settings.write + sales.write + inventory.write
    response.headers['Cache-Control'] = 'no-store'
    @location = Location.find_by!(id: params[:location_id], source: 'ctrax')
    @setting = PosSetting.find_or_initialize_by(location: @location)
  end
  def show; end

  def update
    fields = params.require(:pos_setting).permit(:cash_enabled, :card_enabled, :stock_writes_enabled, :environment, :gateway_id, :gateway_provider, :lock_version)
    submitted = (params[:credentials].is_a?(ActionController::Parameters) ? params[:credentials].permit(:api_login_id, :transaction_key, :security_key, :tokenization_key, :merchant_company, :tpn, :auth_key).to_h : {}).reject { |_key, value| value.blank? }
    saved = PosSetting.transaction do
      @setting.lock! if @setting.persisted?
      @setting.assign_attributes(fields)
      previous = @setting.gateway_provider_changed? || @setting.environment_changed? ? {} : @setting.credentials
      allowed = PosSetting::CREDENTIAL_KEYS.fetch(@setting.gateway_provider, [])
      @setting.credentials_json = JSON.generate(previous.merge(submitted.slice(*allowed)))
      # Blank keeps the saved key; "clear" removes it. Never redisplayed.
      key = params[:webhook_signing_key].to_s.strip
      @setting.webhook_signing_key = key == 'clear' ? nil : key if key.present?
      apply_production_signoff!
      @setting.save
    end
    if saved
      ActivityLogger.log('pos_setup_saved', subject: @setting, details: "POS store configuration#{'; NMI production signed off' if @setting.saved_change_to_production_approved_at? && @setting.production_approved_at}")
      redirect_to pos_setting_path(@location.id), notice: 'POS setup saved.'
    else
      render :show, status: :unprocessable_entity
    end
  rescue ActiveRecord::StaleObjectError
    redirect_to pos_setting_path(@location.id), alert: 'Setup changed. Reload before saving.'
  end

  def verify
    raise Pos::Error, 'Save the settings first.' unless @setting.persisted?
    gateway = case @setting.gateway_provider
              when 'nmi' then Pos::NmiGateway.new(@setting)
              when 'dejavoo_spin' then Pos::DejavooSpinGateway.new(@setting)
              else Pos::Gateway.new(@setting)
              end
    # A Dejavoo check proves the TPN, auth key and terminal connection; there is no browser key.
    client_key = @setting.gateway_provider == 'dejavoo_spin' ? (gateway.verify! && nil) : gateway.merchant.fetch('publicClientKey')
    count = PosSetting.where(id: @setting.id, lock_version: gateway.version).update_all(public_client_key: client_key, verified_at: Time.current, updated_at: Time.current, lock_version: gateway.version + 1)
    raise Pos::Error, 'Setup changed during the check.' if count.zero?
    notice = if @setting.gateway_provider == 'dejavoo_spin'
      'Dejavoo sandbox terminal reached through SPIn with this TPN and auth key. Enable card charges, then run a test sale on the terminal.'
    elsif @setting.gateway_provider == 'nmi'
      "NMI #{@setting.environment} company/profile read verified. Enable card checkout, then run a test sale; payment permissions are proven by the first approved payment."
    else
      'Gateway identity, USD and hosted-card key verified. Enable card payments when ready.'
    end
    redirect_to pos_setting_path(@location.id), notice: notice
  rescue Pos::Error => e
    redirect_to pos_setting_path(@location.id), alert: e.message
  end

  private

  # NMI production is allowed only after an owner (admin) confirms the processor
  # approved this merchant account, and says who approved it and when.
  def apply_production_signoff!
    return unless @setting.gateway_provider == 'nmi' && @setting.environment == 'production'
    return if @setting.production_approved_at && !@setting.environment_changed? && !@setting.gateway_provider_changed? && !@setting.gateway_id_changed?
    return unless params[:nmi_production_signoff] == '1'

    raise Pundit::NotAuthorizedError unless Current.user.admin? || Current.user.super_admin?

    @setting.production_approved_at = Time.current
    @setting.production_approved_by = Current.user
    @setting.production_approval_note = params[:production_approval_note].to_s.strip
  end
end
