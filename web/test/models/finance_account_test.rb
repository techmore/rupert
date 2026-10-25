# frozen_string_literal: true

require 'test_helper'

class FinanceAccountTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
  end

  teardown { Current.tenant = nil }

  test 'valid account is saved' do
    account = Finance::Account.new(code: '7000', name: 'Misc income', account_type: 'revenue')
    assert account.valid?
    account.save!
    assert_equal 'credit', account.normal_balance
  end

  test 'normal balance defaults from account type' do
    { 'expense' => 'debit', 'asset' => 'debit', 'liability' => 'credit', 'equity' => 'credit',
      'revenue' => 'credit' }.each do |type, balance|
      account = Finance::Account.new(code: "9#{type}00", name: type, account_type: type)
      account.valid?
      assert_equal balance, account.normal_balance
    end
  end

  test 'code is unique per tenant' do
    Finance::Account.create!(code: '1000', name: 'Cash', account_type: 'asset')
    duplicate = Finance::Account.new(code: '1000', name: 'Other cash', account_type: 'asset')
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:code], 'has already been taken'
  end

  test 'account type must be a known classification' do
    account = Finance::Account.new(code: '9000', name: 'Bad', account_type: 'mystery')
    assert_not account.valid?
    assert_includes account.errors[:account_type], 'is not included in the list'
  end

  test 'label combines code and name' do
    account = Finance::Account.new(code: '1200', name: 'Inventory')
    assert_equal '1200 · Inventory', account.label
  end

  # Audit #169 M6: the balance sheet reads the balance side, so it must match the type.
  test 'normal balance must match the account type' do
    account = Finance::Account.new(code: '9100', name: 'Wrong side', account_type: 'expense', normal_balance: 'credit')
    assert_not account.valid?
    assert_includes account.errors[:normal_balance], 'must be debit for expense accounts.'

    unused = Finance::Account.create!(code: '9101', name: 'Spare', account_type: 'liability')
    assert_not unused.update(account_type: 'asset')
    assert_includes unused.errors[:normal_balance], 'must be debit for asset accounts.'
    assert unused.update(account_type: 'asset', normal_balance: 'debit')
  end

  test 'an older mismatched account still loads and can be renamed' do
    account = Finance::Account.create!(code: '9102', name: 'Legacy', account_type: 'revenue')
    account.update_column(:normal_balance, 'debit')
    account = Finance::Account.find(account.id)
    assert account.update(name: 'Legacy renamed', active: false)
    assert_equal 'debit', account.reload.normal_balance
  end
end
