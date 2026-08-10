# frozen_string_literal: true

module Finance
  # Chart of accounts: the ledger's account codes, grouped by type. New tenants
  # get the standard chart seeded automatically; existing tenants are seeded on
  # first visit if empty (idempotent).
  class ChartOfAccountsController < AuthenticatedController
    before_action :seed_if_empty
    before_action :set_account, only: [:edit, :update, :archive, :restore]

    def index
      authorize(:module, :finance_read?)
      accounts = Account.ordered
      @grouped = Account::TYPES.each_with_object({}) do |type, out|
        out[type] = accounts.select { |a| a.account_type == type }
      end
      @active_count = accounts.count(&:active)
    end

    def new
      authorize(:module, :finance_write?)
      @account = Account.new
    end

    def create
      authorize(:module, :finance_write?)
      @account = Account.new(account_params)
      if @account.save
        redirect_to finance_chart_of_accounts_path, notice: "Account #{@account.code} created."
      else
        render(:new, status: :unprocessable_entity)
      end
    end

    def edit
      authorize(:module, :finance_write?)
    end

    def update
      authorize(:module, :finance_write?)
      if @account.update(account_params)
        redirect_to finance_chart_of_accounts_path, notice: "Account #{@account.code} updated."
      else
        render(:edit, status: :unprocessable_entity)
      end
    end

    def archive
      authorize(:module, :finance_write?)
      @account.update!(active: false)
      redirect_to finance_chart_of_accounts_path, notice: "Account #{@account.code} archived."
    end

    def restore
      authorize(:module, :finance_write?)
      @account.update!(active: true)
      redirect_to finance_chart_of_accounts_path, notice: "Account #{@account.code} restored."
    end

    private

    def set_account
      @account = Account.find(params[:id])
    end

    # Guarantee the standard chart exists without requiring a rake step.
    def seed_if_empty
      ChartOfAccounts.seed! if Current.user&.can?("finance.read") && Account.count.zero?
    end

    def account_params
      params.require(:account).permit(:code, :name, :account_type, :normal_balance, :description, :active)
    end
  end
end
