# frozen_string_literal: true

module Finance
  # Expense register: money-out records with categories.
  class ExpensesController < AuthenticatedController
    before_action :set_expense, only: %i[edit update destroy restore]

    def index
      authorize(:module, :finance_read?)
      @category = params[:category].presence || 'all'
      @range_days = params[:days].present? ? params[:days].to_i.clamp(7, 365) : 90
      since = @range_days.days.ago.to_date

      scope = Finance::Expense.by_category(@category).since(since)
      scope = scope.with_discarded if params[:include_deleted] == '1'
      @expenses = scope.recent(200).includes(:vendor)
      @include_deleted = params[:include_deleted] == '1'
      @total_cents = @expenses.sum(:amount_cents)
      @by_category = Finance::Expense.since(since).group(:category).sum(:amount_cents)
                                     .sort_by { |_k, v| -v }.first(8)

      return unless params[:format] == 'csv'

      send_data(expenses_csv(@expenses), filename: "expenses-#{@range_days}d.csv")
    end

    def new
      authorize(:module, :finance_write?)
      @expense = Finance::Expense.new(incurred_on: Date.today)
      @vendors = Purchasing::Vendor.ordered
    end

    def create
      authorize(:module, :finance_write?)
      @expense = Finance::Expense.new(expense_params)
      if @expense.save
        ActivityLogger.log(
          'expense_recorded',
          subject: @expense,
          details: "$#{format('%.2f', @expense.amount_cents / 100.0)} · #{@expense.category}"
        )
        redirect_to(finance_expenses_path, notice: 'Expense recorded.')
      else
        @vendors = Purchasing::Vendor.ordered
        render(:new, status: :unprocessable_entity)
      end
    end

    def edit
      authorize(:module, :finance_write?)
      @vendors = Purchasing::Vendor.ordered
    end

    def update
      authorize(:module, :finance_write?)
      if @expense.update(expense_params)
        ActivityLogger.log('expense_updated', subject: @expense)
        redirect_to(finance_expenses_path, notice: 'Expense updated.')
      else
        @vendors = Purchasing::Vendor.ordered
        render(:edit, status: :unprocessable_entity)
      end
    end

    def destroy
      authorize(:module, :finance_write?)
      @expense.discard
      ActivityLogger.log('expense_deleted', subject: @expense)
      redirect_to(finance_expenses_path, notice: 'Expense removed.')
    end

    # Restore a discarded expense back into the register.
    def restore
      authorize(:module, :finance_write?)
      @expense.undiscard
      ActivityLogger.log('expense_restored', subject: @expense)
      redirect_to(finance_expenses_path, notice: 'Expense restored.')
    end

    private

    def expenses_csv(expenses)
      require 'csv'
      CSV.generate do |csv|
        csv << %w[Date Payee Category Method Amount Vendor Reference Notes]
        expenses.each do |expense|
          csv << [
            expense.incurred_on,
            expense.payee,
            expense.category,
            expense.method,
            expense.amount_cents / 100.0,
            expense.vendor&.name,
            expense.reference,
            expense.notes
          ]
        end
      end
    end

    def set_expense
      @expense = Finance::Expense.unscoped.find_by!(tenant_id: Current.tenant_id, id: params[:id])
    end

    def expense_params
      params.require(:expense).permit(:payee, :category, :amount, :incurred_on, :method, :reference, :notes, :vendor_id)
            .tap do |p|
              amount = p.delete(:amount)
              p[:amount_cents] = (amount.to_f * 100).round if amount.present?
            end
    end
  end
end
