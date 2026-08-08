# frozen_string_literal: true

class SettingsController < AuthenticatedController
  def show; end

  # GET /settings/env.json — masked view of managed env keys
  def env
    render json: {
      keys: EnvStore::MANAGED_KEYS.map do |key|
        value = EnvStore.fetch(key, "")
        { key: key, set: value.present?, masked: value.present? ? EnvStore.mask(value) : nil,
          source: Setting.exists?(key: key) ? "database" : "environment" }
      end
    }
  end

  # POST /settings/env_import — JSON { text: } or multipart .env upload
  def env_import
    text = if params[:text].present?
             params[:text]
           elsif params[:file].present?
             params[:file].read
           end
    raise ArgumentError, "Provide .env text or a file" if text.blank?

    imported = EnvStore.import!(text)
    render json: { ok: true, imported: imported }
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  end

  # GET /settings/env_export — raw .env text of managed keys
  def env_export
    body = EnvStore.export.map { |key, value| "#{key}=#{value}" }.join("\n") + "\n"
    render plain: body, content_type: "text/plain"
  end

  # GET /settings/backup — consistent SQLite snapshot download
  def backup
    path = BackupService.snapshot_path
    send_file path, filename: "rupert-backup-#{Time.now.strftime("%Y%m%d-%H%M%S")}.sqlite3",
      type: "application/octet-stream"
  end

  # POST /settings/restore — upload a .sqlite3 backup and swap it in
  def restore
    file = params[:file]
    raise ArgumentError, "No file uploaded" if file.nil?

    path = file.tempfile.path
    BackupService.restore!(path)
    render json: { ok: true }
  rescue BackupService::RestoreError, ArgumentError => e
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  end
end
