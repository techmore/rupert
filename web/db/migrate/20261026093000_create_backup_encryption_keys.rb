# frozen_string_literal: true

# Public halves of the age keys that encrypt backups (#421). The private half is printed once on the owner's
# recovery kit PDF and never stored here. Plaintext on purpose: bin/backup.sh and the frequent snapshot read the
# active recipient with the sqlite3 CLI, which cannot decrypt Active Record encrypted columns. A public key is not
# secret. Rows are never deleted, so the fingerprint written next to each backup file can always be matched to the kit
# that opens it.
class CreateBackupEncryptionKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :backup_encryption_keys do |t|
      t.string :recipient, null: false
      t.string :fingerprint, null: false
      # SHA-256 of the check code printed on the kit; typing the code activates the key.
      t.string :confirmation_digest, null: false
      t.bigint :created_by_id
      t.bigint :activated_by_id
      t.datetime :activated_at
      t.datetime :retired_at
      t.timestamps
    end
    add_index :backup_encryption_keys, :recipient, unique: true
    add_index :backup_encryption_keys, %i[activated_at retired_at]
  end
end
