# frozen_string_literal: true

# Schedule and read state for the Square Loyalty mirror. The schedule is an
# explicit per-workspace opt-in (like Square timecards); the state records how far
# the points ledger has been read so each run reads only what is new.
class SquareLoyaltySync
  KEY = 'square_loyalty_schedule'
  STATE_KEY = 'square_loyalty_state'
  INTERVAL = 'every hour'

  class << self
    def configuration
      JSON.parse(Setting.for_tenant(KEY)&.value || '{}')
    rescue JSON::ParserError
      {}
    end

    def enabled?
      configuration['enabled'] == true
    end

    def state
      JSON.parse(Setting.for_tenant(STATE_KEY)&.value || '{}')
    rescue JSON::ParserError
      {}
    end

    def save_state!(values)
      Setting.find_or_create_for(STATE_KEY, Current.tenant_id) { |setting| setting.value = values.to_json }
    end

    # Records a failed run without touching the mirror or the ledger position.
    def record_failure!(error)
      message = error.is_a?(SquareClient::Error) ? error.message : 'The Square loyalty read failed. Previous loyalty data was kept.'
      save_state!(state.merge('last_failure_at' => Time.current.iso8601, 'last_failure' => message.first(500)))
    rescue ActiveRecord::ActiveRecordError
      nil
    end

    def configure!(enabled:, actor: Current.user)
      Tenant.transaction do
        raise Pundit::NotAuthorizedError unless Current.tenant&.status == 'active'

        Tenant.where(id: Current.tenant_id).update_all('updated_at = updated_at')
        actor = authorized_actor(actor&.id)
        raise Pundit::NotAuthorizedError unless actor

        EnvStore.clear_cache!
        raise SquareLoyaltyReader::Error.new('Configure the Square connection first.', reason: :invalid) if enabled && !SquareClient.configured?

        Setting.find_or_create_for(KEY, Current.tenant_id) do |setting|
          setting.value = { enabled: enabled == true, actor_id: actor.id, version: SecureRandom.hex(24) }.to_json
        end
        ActivityLogger.log('square_loyalty_schedule_updated', details: enabled ? 'Read-only Square Loyalty refresh every hour enabled.' : 'Automatic Square Loyalty refresh disabled.')
      end
    end

    # The same people who may run a customer directory sync.
    def authorized_actor(id)
      actor = User.find_by(id: id, active: true)
      return unless actor && (actor.super_admin? || actor.tenant_id == Current.tenant_id)

      actor if actor.can?('customers.write') && actor.can?('sync.write')
    end

    def verify!(snapshot)
      return if snapshot['enabled'] == true && configuration == snapshot && authorized_actor(snapshot['actor_id'])

      raise SquareLoyaltyReader::Error.new('The Square Loyalty schedule changed during the read. Previous loyalty data was kept.', reason: :changed)
    end

    # Scheduled run: only for workspaces that opted in.
    def call
      snapshot = configuration
      return unless snapshot['enabled'] == true

      run(actor_id: snapshot['actor_id'], sync_configuration: snapshot)
    end

    # Manual run ("Sync now"), authorized by the person who asked.
    def run(actor_id:, sync_configuration: nil)
      SyncObservability.observe('square', 'loyalty') do
        verify!(sync_configuration) if sync_configuration
        actor = authorized_actor(actor_id)
        raise Pundit::NotAuthorizedError unless actor

        SquareLoyaltyImport.new(actor: actor, sync_configuration: sync_configuration).call(apply: true)
      rescue StandardError => e
        record_failure!(e)
        raise
      end
    end
  end
end
