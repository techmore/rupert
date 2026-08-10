# frozen_string_literal: true

module Finance
  # Accounts overview: payables (what we owe vendors) and receivables (what
  # customers owe us).
  class AccountsController < AuthenticatedController
    def show
      authorize(:module, :finance_read?)
      @payables = AccountsService.payable_by_vendor
      @payables_total = @payables.sum { |row| row[:balance_cents] }
      @receivables = AccountsService.receivable_by_customer.limit(100)
      @receivables_total = AccountsService.receivable_total_cents
    end
  end
end
