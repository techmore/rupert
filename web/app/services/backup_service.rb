# frozen_string_literal: true

require "fileutils"

# SQLite backup/restore for the Settings GUI + JSON API. Backups use
# VACUUM INTO for a consistent snapshot even while writes are in flight.
class BackupService
  class RestoreError < StandardError; end

  class << self
    def database_path
      ActiveRecord::Base.connection_db_config.database
    end

    def snapshot_path
      dir = Rails.root.join("tmp", "backups")
      FileUtils.mkdir_p(dir)
      if postgres?
        postgres_snapshot_path(dir)
      else
        sqlite_snapshot_path(dir)
      end
    end

    def restore!(source_path)
      validate!(source_path)
      if postgres?
        postgres_restore!(source_path)
      else
        sqlite_restore!(source_path)
      end
      true
    end

    def validate!(source_path)
      raise RestoreError, "Empty backup file" if source_path.nil? || File.empty?(source_path)

      header = File.binread(source_path, 16).to_s
      valid = header.start_with?("SQLite format 3") || header.start_with?("PGDMP")
      raise RestoreError, "Not a SQLite or PostgreSQL backup file" unless valid
    end

    def postgres?
      ActiveRecord::Base.connection_db_config.adapter == "postgresql"
    end

    private

    def sqlite_snapshot_path(dir)
      path = dir.join("rupert-backup-#{Time.now.to_i}.sqlite3")
      connection = ActiveRecord::Base.connection
      quoted = connection.quote(path.to_s)
      connection.execute("VACUUM INTO #{quoted}")
      path
    rescue SQLite3::SQLException
      FileUtils.cp(database_path, path)
      path
    end

    def postgres_snapshot_path(dir)
      path = dir.join("rupert-backup-#{Time.now.to_i}.dump")
      config = ActiveRecord::Base.connection_db_config.configuration_hash
      cmd = ["pg_dump", "--format=custom", "--no-owner", "--file=#{path}"]
      cmd << "--host=#{config[:host]}" if config[:host].present?
      cmd << "--port=#{config[:port]}" if config[:port].present?
      cmd << "--username=#{config[:username]}" if config[:username].present?
      cmd << config[:database]
      env = { "PGPASSWORD" => config[:password].to_s }
      ok = system(env, *cmd, out: File::NULL, err: File::NULL)
      raise RestoreError, "pg_dump failed — is PostgreSQL running?" unless ok && File.exist?(path) && !File.empty?(path)

      path
    end

    def sqlite_restore!(source_path)
      ActiveRecord::Base.connection_pool.disconnect!
      FileUtils.cp(source_path, database_path)
      ActiveRecord::Base.establish_connection
      verify_post_restore!
    end

    def postgres_restore!(source_path)
      config = ActiveRecord::Base.connection_db_config.configuration_hash
      env = { "PGPASSWORD" => config[:password].to_s }
      cmd = [
        "pg_restore",
        "--clean",
        "--if-exists",
        "--no-owner",
        "--host=#{config[:host]}",
        "--port=#{config[:port]}",
        "--username=#{config[:username]}",
        "--dbname=#{config[:database]}",
        source_path,
      ]
      ok = system(env, *cmd, out: File::NULL, err: File::NULL)
      raise RestoreError, "pg_restore failed — the backup may be corrupt" unless ok

      ActiveRecord::Base.connection_pool.disconnect!
      ActiveRecord::Base.establish_connection
      verify_post_restore!
    end

    def verify_post_restore!
      # Touch each core table so a corrupt import fails here, not later.
      [
        "ShopifyProduct",
        "ShopifyVariant",
        "SquareItem",
        "SquareVariation",
        "SkuLink",
        "ReconcileRun",
        "InventoryLevel",
        "StockAlert",
        "SyncRun",
        "LedgerEntry",
      ].each do |table|
        ActiveRecord::Base.connection.execute("SELECT COUNT(*) FROM \"#{table}\"")
      end
    rescue StandardError => e
      raise RestoreError, "Restored database failed validation: #{e.message}"
    end
  end
end
