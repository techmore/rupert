# frozen_string_literal: true

class LedgerEntry < ApplicationRecord
  include HasCuid
  include TenantScoped

  self.table_name = "LedgerEntry"
  self.primary_key = "id"

  SOURCES = %w[shopify square].freeze

  scope :recent, ->(limit = 200) { order(occurredAt: :desc).limit(limit) }
  scope :since, ->(date) { where("occurredAt >= ?", date) }
  scope :by_source, ->(source) { source.present? && source != "all" ? where(source: source) : all }

  def self.gross_by_source(where_clause = {})
    where(where_clause).group(:source).sum(:grossCents)
  end
end
