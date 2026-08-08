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
      path = dir.join("rupert-backup-#{Time.now.to_i}.sqlite3")
      connection = ActiveRecord::Base.connection
      quoted = connection.quote(path.to_s)
      connection.execute("VACUUM INTO #{quoted}")
      path
    rescue SQLite3::SQLException
      # Older SQLite without VACUUM INTO — fall back to a raw copy.
      FileUtils.cp(database_path, path)
      path
    end

    def restore!(source_path)
      validate!(source_path)
      ActiveRecord::Base.connection_pool.disconnect!
      FileUtils.cp(source_path, database_path)
      ActiveRecord::Base.establish_connection
      verify_post_restore!
      true
    end

    def validate!(source_path)
      raise RestoreError, "Empty backup file" if source_path.nil? || File.zero?(source_path)

      header = File.binread(source_path, 16).to_s
      unless header.start_with?("SQLite format 3")
        raise RestoreError, "Not a SQLite database file"
      end
    end

    def verify_post_restore!
      # Touch each core table so a corrupt import fails here, not later.
      %w[ShopifyProduct ShopifyVariant SquareItem SquareVariation SkuLink
         ReconcileRun InventoryLevel StockAlert SyncRun LedgerEntry].each do |table|
        ActiveRecord::Base.connection.execute("SELECT COUNT(*) FROM \"#{table}\"")
      end
    rescue StandardError => e
      raise RestoreError, "Restored database failed validation: #{e.message}"
    end
  end
end
