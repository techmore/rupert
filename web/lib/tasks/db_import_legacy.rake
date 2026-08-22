# frozen_string_literal: true

namespace :db do
  desc 'Import data from the legacy Prisma SQLite database (legacy/prisma/dev.sqlite)'
  task import_legacy: :environment do
    legacy_path = Rails.root.join('..', 'legacy', 'prisma', 'dev.sqlite')

    abort("Legacy database not found at #{legacy_path}. Nothing to import.") unless File.exist?(legacy_path)

    # Prisma stores DateTime columns as epoch milliseconds (integers) while
    # Rails stores them as ISO8601 text — convert on the way in.
    datetime_columns = {
      'ShopifyProduct' => %w[publishedAt syncedAt],
      'ShopifyVariant' => ['syncedAt'],
      'SquareItem' => ['syncedAt'],
      'SquareVariation' => ['syncedAt'],
      'SkuLink' => ['createdAt'],
      'ReconcileRun' => %w[startedAt finishedAt],
      'ReconcileItem' => [],
      'Location' => ['syncedAt'],
      'InventoryLevel' => ['updatedAt'],
      'InventoryMovement' => ['createdAt'],
      'StockAlert' => %w[createdAt resolvedAt],
      'SyncRun' => %w[startedAt finishedAt],
      'InventoryPolicy' => ['updatedAt'],
      'LedgerEntry' => %w[occurredAt syncedAt]
    }

    connection = ActiveRecord::Base.connection
    connection.execute("ATTACH DATABASE #{connection.quote(legacy_path.to_s)} AS legacy")

    datetime_columns.each do |table, dt_cols|
      rows = connection.select_all(<<~SQL)
        SELECT * FROM legacy."#{table}"
      SQL
      next if rows.empty?

      columns = rows.first.keys
      values_placeholder = columns.map { '?' }.join(', ')
      quoted_columns = columns.map { |c| connection.quote_column_name(c) }.join(', ')

      inserted = 0
      connection.transaction do
        rows.each do |row|
          values = columns.map do |col|
            value = row[col]
            if dt_cols.include?(col) && value.is_a?(Numeric)
              Time.at(value / 1000.0).utc.strftime('%Y-%m-%d %H:%M:%S.%6N')
            else
              value
            end
          end
          connection.exec_query(
            %(INSERT OR IGNORE INTO "#{table}" (#{quoted_columns}) VALUES (#{values_placeholder})),
            "Import #{table}",
            values
          )
          inserted += 1
        end
      end

      puts "Imported #{inserted} rows into #{table} (#{legacy_path})"
    end
  ensure
    begin
      connection&.execute('DETACH DATABASE legacy')
    rescue StandardError
      nil
    end
  end
end
