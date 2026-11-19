# frozen_string_literal: true

# Rupert on-hand for one item at one site. Created by the first count; only
# MasterStock::Ledger changes it, always together with a ledger entry.
class StockBalance < ApplicationRecord
  include TenantScoped

  belongs_to :stock_item
  belongs_to :stock_site

  validates :on_hand, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
