class CreateBackupLogs < ActiveRecord::Migration[8.1]
  def change
    create_table "BackupLog", id: :string do |t|
      t.string "status", default: "running", null: false
      t.datetime "startedAt", null: false
      t.datetime "finishedAt"
      t.string "fileName"
      t.integer "fileSize"
      t.string "driveFileId"
      t.string "driveUrl"
      t.text "error"
      t.string "tenant_id"
    end
    add_index "BackupLog", ["tenant_id", "startedAt"]
  end
end
