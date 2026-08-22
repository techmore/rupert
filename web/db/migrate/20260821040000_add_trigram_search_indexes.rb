# frozen_string_literal: true

# Trigram indexes for the global search's leading-wildcard ILIKE queries
# (SearchService). Without pg_trgm, '%term%' ILIKE forces a sequential scan on
# the largest tables — orders, customers, and variants.
class AddTrigramSearchIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEXES = {
    'orders' => [['order_number'], ['source_order_id']],
    'customers' => [['email'], ['phone'], ['first_name'], ['last_name']],
    'ShopifyVariant' => [['sku'], ['title']]
  }.freeze

  def up
    enable_extension 'pg_trgm' unless extension_enabled?('pg_trgm')

    INDEXES.each do |table, columns|
      columns.each do |column|
        name = "idx_trgm_#{table}_#{column.first}"
        execute <<~SQL.squish
          CREATE INDEX CONCURRENTLY IF NOT EXISTS #{name}
          ON "#{table}" USING gin (#{column.map { |c| "\"#{c}\"" }.join(" || ' ' || ")} gin_trgm_ops)
        SQL
      end
    end
  end

  def down
    INDEXES.each do |table, columns|
      columns.each do |column|
        execute "DROP INDEX IF EXISTS idx_trgm_#{table}_#{column.first}"
      end
    end
  end
end
