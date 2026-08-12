# frozen_string_literal: true

module Finance
  # Accounts overview: payables (what we owe vendors) and receivables (what
  # customers owe us).
  class AccountsController < AuthenticatedController
    def show
      authorize(:module, :finance_read?)
      @payables = DataCache.fetch("finance/payables") { AccountsService.payable_by_vendor }
      @payables_total = @payables.sum { |row| row[:balance_cents] }
      @receivables = DataCache.fetch("finance/receivables") { AccountsService.receivable_by_customer }
      @receivables_total = @receivables.sum { |r| r[:balance_cents] }
      @receivables = @receivables.first(100)
    end
  end
end
