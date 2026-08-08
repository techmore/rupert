# frozen_string_literal: true

# One-time task: migrate production.sqlite3 data into PostgreSQL.
# Usage: bin/rails db:sqlite_to_postgres
#
# Copies every business table row-for-row, preserving ids (cuid + bigint).
# Type-aware: SQLite booleans (1/0) are cast to real PG booleans.
# Idempotent: truncates each target table before inserting.
# Solid Queue job tables are intentionally skipped (transient runtime data).
namespace :db do
  desc "Copy production.sqlite3 data into the configured PostgreSQL database"
  task sqlite_to_postgres: :environment do
    sqlite_path = ENV.fetch("SQLITE_DB", "db/production.sqlite3")
    raise "SQLite file not found: #{sqlite_path}" unless File.exist?(sqlite_path)

    require "sqlite3"
    sqlite = SQLite3::Database.new(sqlite_path)
    sqlite.results_as_hash = true

    pg = ActiveRecord::Base.connection

    tables = pg.tables.reject { |t| t.start_with?("solid_queue", "ar_internal", "schema_migrations") }.sort
    counts = {}

    tables.each do |table|
      cols = pg.columns(table)
      boolean_cols = cols.select { |c| c.type == :boolean }.map(&:name)
      int_cols = cols.select { |c| [:integer, :bigint].include?(c.type) }.map(&:name)

      rows = sqlite.execute("SELECT * FROM \"#{table}\"")
      next if rows.empty?

      counts[table] = rows.length
      pg.execute("TRUNCATE \"#{table}\" RESTART IDENTITY")

      quoted_cols = cols.map { |c| pg.quote_column_name(c.name) }.join(", ")

      rows.each_slice(500) do |batch|
        values = batch.map do |row|
          "(#{cols.map do |c|
            v = row[c.name]
            if v.nil?
              "NULL"
            elsif boolean_cols.include?(c.name)
              v.to_i.zero? ? "FALSE" : "TRUE"
            elsif int_cols.include?(c.name) && v.is_a?(String)
              v.empty? ? "NULL" : v.to_i.to_s
            else
              pg.quote(v)
            end
          end.join(", ")})"
        end.join(", ")
        pg.execute("INSERT INTO \"#{table}\" (#{quoted_cols}) VALUES #{values}")
      end
      puts "  #{table}: #{rows.length}"
    end

    puts "\nMigration complete:"
    counts.each { |t, c| puts "  #{t}: #{c} rows" }
  end
end
