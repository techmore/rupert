# frozen_string_literal: true

class BankConnectionsController < AuthenticatedController
  before_action -> { authorize(:module, :finance_read?) }
  before_action -> { authorize(:module, :finance_write?) }, except: :show
  before_action -> { authorize(:module, :settings_write?) }, only: :update
  before_action :load_connection
  before_action :prevent_caching
  rescue_from BankFeed::PlaidClient::Error, with: :connection_error

  def show
    @can_write = Current.user.can?('finance.write')
    @can_configure = @can_write && Current.user.can?('settings.write')
    @changes = BankFeedEntry.joins(:bank_statement_line).where(bank_connection: @connection)
      .where(bank_statement_lines: { source_state: %w[changed removed], status: 'recorded' }).order(updated_at: :desc).limit(50)
    if params[:oauth_state_id].present?
      valid_flow!
      @resume_link = true
    end
  end

  def update
    @connection.with_lock do
      raise BankFeed::PlaidClient::Error.new('DISCONNECT_BEFORE_SETUP_CHANGE') if @connection.connected?
      environment = params.require(:bank_connection).fetch(:environment)
      values = params.require(:bank_connection).permit(:client_id, :secret).to_h.reject { |_, value| value.blank? }
      old = @connection.environment == environment ? @connection.credentials : {}
      @connection.update!(environment: environment, credentials_json: old.merge(values).to_json, last_error_code: nil,
        consent_version: @connection.consent_version + 1)
    end
    session.delete(:wells_fargo_link)
    ActivityLogger.log('bank_connection_configured', details: @connection.environment)
    redirect_to bank_connection_path, notice: 'Plaid setup saved. Connect Wells Fargo to authorize hourly transaction sync.'
  rescue ActiveRecord::RecordInvalid
    redirect_to bank_connection_path, alert: 'Choose Sandbox or Production and enter valid Plaid setup.'
  end

  def link_token
    raise BankFeed::PlaidClient::Error.new('HTTPS_REQUIRED') if @connection.environment == 'production' && !request.ssl?
    @connection.with_lock do
      mode = @connection.connected? ? 'update' : 'connect'
      body = { client_name: 'Rupert', language: 'en', country_codes: ['US'],
        user: { client_user_id: "#{Current.tenant_id}:#{Current.user.id}" }, redirect_uri: bank_connection_url }
      if mode == 'update'
        body[:access_token] = @connection.access_token
      else
        body[:products] = ['transactions']
        body[:transactions] = { days_requested: 90 }
        body[:account_filters] = { depository: { account_subtypes: %w[checking savings] } }
      end
      result = @connection.client.call('link/token/create', **body)
      session[:wells_fargo_link] = { 'token' => result.fetch('link_token'), 'tenant' => Current.tenant_id,
        'user' => Current.user.id, 'expires' => 30.minutes.from_now.to_i, 'mode' => mode, 'item' => @connection.item_id,
        'environment' => @connection.environment, 'consent_version' => @connection.consent_version }
      render json: { link_token: result.fetch('link_token') }
    end
  end

  def resume
    render json: { link_token: valid_flow!.fetch('token') }
  end

  def exchange
    @connection.with_lock do
      flow = valid_flow!
      if flow.fetch('mode') == 'update'
        item_id = @connection.client.verify_wells_fargo!(@connection.access_token)
        raise BankFeed::PlaidClient::Error.new('ITEM_CHANGED') unless item_id == @connection.item_id
        @connection.update!(sync_enabled: true, last_error_code: nil)
      else
        token = params.require(:public_token).to_s
        raise BankFeed::PlaidClient::Error.new('INVALID_TOKEN') unless token.bytesize.between?(1, 512)
        result = @connection.client.call('item/public_token/exchange', public_token: token)
        access = result.fetch('access_token')
        begin
          item = @connection.client.verify_wells_fargo!(access)
          raise BankFeed::PlaidClient::Error.new('ITEM_CHANGED') unless item == result.fetch('item_id')
          @connection.update!(access_token: access, item_id: item, cursor: nil, last_synced_at: nil, sync_enabled: true, last_error_code: nil)
        rescue StandardError
          @connection.client.call('item/remove', access_token: access)
          raise
        end
      end
      @connection.update!(consent_version: @connection.consent_version + 1)
    end
    session.delete(:wells_fargo_link)
    BankFeedSyncJob.perform_later(Current.tenant_id)
    ActivityLogger.log('bank_connected', details: @connection.environment)
    render json: { redirect_url: bank_connection_path }
  end

  def sync
    raise BankFeed::PlaidClient::Error.new('CONNECT_FIRST') unless @connection.connected? && @connection.sync_enabled?
    BankFeedSyncJob.perform_later(Current.tenant_id)
    redirect_to bank_connection_path, notice: 'Bank sync queued. New posted transactions will appear under Bank statements for review.'
  end

  def disconnect
    # Stop local pulls even if Plaid is temporarily unable to revoke access.
    # Retain the encrypted token on failure so revocation can be retried.
    @connection.with_lock { @connection.update!(sync_enabled: false, consent_version: @connection.consent_version + 1) }
    session.delete(:wells_fargo_link)
    @connection.with_lock do
      @connection.client.call('item/remove', access_token: @connection.access_token) if @connection.connected?
      @connection.update!(access_token: nil, item_id: nil, cursor: nil, sync_enabled: false, last_error_code: nil)
    end
    session.delete(:wells_fargo_link)
    ActivityLogger.log('bank_disconnected', details: 'Wells Fargo access revoked; imported evidence retained')
    redirect_to bank_connection_path, notice: 'Wells Fargo disconnected. Imported lines and evidence are retained.'
  end

  private

  def load_connection
    unless Current.user.active? && Current.tenant&.status == 'active'
      render plain: 'An active workspace and account are required.', status: :forbidden
      return
    end
    @connection = BankConnection.find_or_create_by!(tenant_id: Current.tenant_id)
  rescue ActiveRecord::RecordNotUnique
    @connection = BankConnection.find_by!(tenant_id: Current.tenant_id)
  end

  def prevent_caching
    response.headers['Cache-Control'] = 'private, no-store'
    response.headers['Referrer-Policy'] = 'no-referrer'
    response.headers['Pragma'] = 'no-cache'
  end

  def valid_flow!
    flow = session[:wells_fargo_link]
    valid = flow.is_a?(Hash) && flow['tenant'] == Current.tenant_id && flow['user'] == Current.user.id &&
      flow['expires'].to_i > Time.current.to_i && flow['environment'] == @connection.environment &&
      flow['item'] == @connection.item_id && flow['consent_version'] == @connection.consent_version
    raise BankFeed::PlaidClient::Error.new('LINK_EXPIRED') unless valid
    flow
  end

  def connection_error(error)
    message = "#{error.message} (#{error.code})"
    message += ' Automatic sync is paused; retry Disconnect to revoke bank access.' if action_name == 'disconnect'
    if request.format.json?
      render json: { error: message }, status: :unprocessable_entity
    else
      redirect_to bank_connection_path, alert: message
    end
  end
end
