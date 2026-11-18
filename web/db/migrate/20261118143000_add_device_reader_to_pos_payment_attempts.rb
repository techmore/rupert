# frozen_string_literal: true

# A card payment the phone starts (Pos::DeviceReaderPayment): the phone talks
# to the card reader and Rupert's server stays the system of record. Additive
# only: four nullable columns and one partial index, no table rewrite and no
# data change. Existing attempts keep provider NULL and are untouched.
#
# - provider: 'device_reader' for these attempts (NULL = the checkout's gateway).
# - device_digest: SHA-256 of the app install that started the reader.
# - device_report_json: the whitelisted result the phone reported. A hint only;
#   never a card number. The gateway lookup decides the outcome.
# - device_reported_at: when that hint arrived.
#
# The attempt's single-use token is not a column: its digest lives in the
# existing nonce_digest (unique per workspace).
#
# The index makes "one unresolved phone attempt per checkout" a database rule.
class AddDeviceReaderToPosPaymentAttempts < ActiveRecord::Migration[8.1]
  INDEX = 'index_pos_payment_attempts_one_open_device_reader'

  def up
    add_column :pos_payment_attempts, :provider, :string unless column_exists?(:pos_payment_attempts, :provider)
    add_column :pos_payment_attempts, :device_digest, :string unless column_exists?(:pos_payment_attempts, :device_digest)
    add_column :pos_payment_attempts, :device_report_json, :text unless column_exists?(:pos_payment_attempts, :device_report_json)
    add_column :pos_payment_attempts, :device_reported_at, :datetime unless column_exists?(:pos_payment_attempts, :device_reported_at)
    return if index_exists?(:pos_payment_attempts, :pos_checkout_id, name: INDEX)

    add_index :pos_payment_attempts, :pos_checkout_id, unique: true, name: INDEX,
      where: "provider = 'device_reader' AND status IN ('submitting', 'unknown')"
  end

  def down
    remove_index :pos_payment_attempts, name: INDEX if index_exists?(:pos_payment_attempts, :pos_checkout_id, name: INDEX)
    %i[device_reported_at device_report_json device_digest provider].each do |column|
      remove_column :pos_payment_attempts, column if column_exists?(:pos_payment_attempts, column)
    end
  end
end
