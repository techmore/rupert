# frozen_string_literal: true

require 'test_helper'

class FinanceExpenseWorkspaceTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    @other = Tenant.create!(name: 'Other shop', subdomain: 'expense-other', status: 'active')
    Current.tenant = @tenant
    @vendor = Purchasing::Vendor.create!(name: 'Our vendor')
    @account = Finance::Account.create!(code: '6990', name: 'Our expense', account_type: 'expense')
    Current.set(tenant: @other) do
      @foreign_vendor = Purchasing::Vendor.create!(name: 'Their vendor')
      @foreign_account = Finance::Account.create!(code: '6990', name: 'Their expense', account_type: 'expense')
    end
  end

  teardown { Current.reset }

  def expense(**attrs)
    Finance::Expense.new(payee: 'Supplier', category: 'supplies', amount_cents: 1200, incurred_on: Date.current, **attrs)
  end

  test 'a vendor and ledger account from this workspace are accepted' do
    assert expense(vendor_id: @vendor.id, account_id: @account.id).valid?
  end

  test 'a vendor or ledger account from another workspace is rejected' do
    record = expense(vendor_id: @foreign_vendor.id, account_id: @foreign_account.id)
    assert_not record.valid?
    assert_includes record.errors[:vendor], 'must belong to this workspace'
    assert_includes record.errors[:account], 'must belong to this workspace'

    saved = expense
    saved.save!
    assert_not saved.update(vendor_id: @foreign_vendor.id)
    assert_nil saved.reload.vendor_id
  end

  test 'an expense category cannot map to another workspace ledger account' do
    category = Finance::ExpenseCategory.new(name: 'Foreign mapped', ledger_account_id: @foreign_account.id)
    assert_not category.valid?
    assert_includes category.errors[:ledger_account], 'must be an expense account in this workspace'
    category.ledger_account_id = @account.id
    category.valid?
    assert_empty category.errors[:ledger_account]
  end
end
