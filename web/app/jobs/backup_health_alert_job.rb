# frozen_string_literal: true

# Hourly: when backups are off or failing (BackupHealth), every active instance owner (super admin) gets one in-app
# notification per day until it is fixed. The bell and the dashboard show the live state on every page; this leaves
# a dated record for someone who has not looked. Backups failed unnoticed from late October to Nov 11, 2026.
class BackupHealthAlertJob < ApplicationJob
  queue_as :default

  def perform
    return unless BackupHealth.alerts_enabled?

    health = BackupHealth.current
    return unless health.alert?

    User.where(role: 'super_admin', active: true).find_each do |owner|
      tenant = Tenant.find_by(id: owner.tenant_id)
      next unless tenant

      Current.with_tenant(tenant) do
        Notification.deliver(owner.id, kind: 'backup_health', title: health.title, body: health.summary,
          url: '/settings/backups', dedupe_key: "backup-health:#{Time.current.utc.to_date.iso8601}", actor: nil)
      end
    end
  end
end
