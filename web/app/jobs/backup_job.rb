# frozen_string_literal: true

# Scheduled Google Drive backups, one per connected tenant.
class BackupJob < ApplicationJob
  queue_as :default

  def perform
    Tenant.where(status: 'active').find_each do |tenant|
      Current.tenant = tenant
      next unless GoogleDriveBackupService.connected?

      GoogleDriveBackupService.backup!(actor: 'scheduler')
    rescue GoogleDriveBackupService::NotConnectedError
      nil
    end
  ensure
    Current.tenant = nil
  end
end
