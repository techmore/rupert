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
end
