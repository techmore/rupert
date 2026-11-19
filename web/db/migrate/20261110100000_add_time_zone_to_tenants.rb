# frozen_string_literal: true

# A workspace's own clock (multi-tenant time & pay). NULL keeps the instance default
# (config.time_zone), so the existing workspace behaves exactly as before. Additive only.
#
# push_devices: a phone's push token is looked up across workspaces when the phone signs in to
# another one, so the previous person's notifications stop (PushDevice.register!).
class AddTimeZoneToTenants < ActiveRecord::Migration[8.1]
  def change
    add_column :tenants, :time_zone, :string
    add_index :push_devices, :token_digest, name: 'idx_push_devices_token_digest'
  end
end
