# frozen_string_literal: true

require 'test_helper'

class BankFeedSyncTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @connection = BankConnection.create!(credentials_json: { client_id: 'client', secret: 'secret' }.to_json,
      access_token: 'access-test', item_id: 'item-test', sync_enabled: true)
  end
  teardown { Current.reset }

  def transaction(id: 'txn-1', amount: 12.34, pending: false, **extra)
    { transaction_id: id, account_id: 'account-1', date: '2026-10-14', amount: amount, pending: pending,
      name: 'UPS STORE', iso_currency_code: 'USD', unofficial_currency_code: nil }.merge(extra)
  end

  def page(added: [], modified: [], removed: [], cursor: 'cursor-1', more: false)
    { accounts: [{ account_id: 'account-1', type: 'depository', subtype: 'checking' }],
      added: added, modified: modified, removed: removed.map { |id| { transaction_id: id } }, next_cursor: cursor, has_more: more }
  end

  def stub_sync(*responses)
    stub_request(:post, 'https://sandbox.plaid.com/transactions/sync').to_return(*responses.map { |body| { status: 200, body: body.to_json } })
  end

  test 'posted USD transactions enter review once with the correct sign and encrypted evidence' do
    stub_sync(page(added: [transaction, transaction(id: 'deposit', amount: -50)]))
    assert_no_difference(['Finance::Expense.count', 'Finance::VendorPayment.count']) { BankFeed::Sync.call(@connection) }
    assert_equal [-1234, 5000], BankStatementLine.order(:id).pluck(:amount_cents)
    assert BankStatementLine.first.account_label.start_with?('Sandbox Wells Fargo')
    assert_equal 'cursor-1', @connection.reload.cursor
    assert_equal 1, ReconciliationDocument.where(kind: 'bank_statement').count
    assert_equal 2, BankStatementLine.pending.count
    assert_no_difference 'BankStatementLine.count' do
      BankFeed::Sync.call(@connection)
    end
    raw = ActiveRecord::Base.connection.select_value('SELECT access_token FROM bank_connections LIMIT 1')
    assert_not_includes raw, 'access-test'
    raw = ActiveRecord::Base.connection.select_value('SELECT payload_json FROM bank_feed_entries LIMIT 1')
    assert_not_includes raw, 'UPS STORE'
  end

  test 'pending transactions never enter review and can later post under the same id' do
    stub_sync(page(added: [transaction(pending: true)]), page(modified: [transaction], cursor: 'cursor-2'))
    BankFeed::Sync.call(@connection)
    assert_equal 0, BankStatementLine.count
    BankFeed::Sync.call(@connection)
    assert_equal 1, BankStatementLine.count
    assert_equal 1, BankFeedEntry.count
  end

  test 'pending to posted replacement ids do not duplicate a line' do
    stub_sync(page(added: [transaction(pending: true)]),
      page(added: [transaction(id: 'posted')], removed: ['txn-1'], cursor: 'cursor-2'))
    2.times { BankFeed::Sync.call(@connection) }
    assert_equal 1, BankStatementLine.count
    assert_equal 2, BankFeedEntry.count
  end

  test 'pagination commits together and later replay is idempotent' do
    stub_sync(page(added: [transaction], more: true), page(added: [transaction(id: 'txn-2')], cursor: 'cursor-2'))
    BankFeed::Sync.call(@connection)
    assert_equal 2, BankStatementLine.count
    assert_equal 'cursor-2', @connection.reload.cursor
  end

  test 'pagination mutation restarts at the original cursor without committing partial pages' do
    @connection.update!(cursor: 'original')
    stub_request(:post, 'https://sandbox.plaid.com/transactions/sync').to_return(
      { status: 200, body: page(added: [transaction], more: true).to_json },
      { status: 400, body: { error_code: 'TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION' }.to_json },
      { status: 200, body: page(added: [transaction(id: 'final')], cursor: 'final-cursor').to_json })
    BankFeed::Sync.call(@connection)
    assert_equal 'final-cursor', @connection.reload.cursor
    assert_equal 1, BankStatementLine.count
    assert_requested(:post, 'https://sandbox.plaid.com/transactions/sync', times: 2) { |request| JSON.parse(request.body)['cursor'] == 'original' }
  end

  test 'failure on a later page leaves no evidence or lines and does not advance the cursor' do
    @connection.update!(cursor: 'original')
    stub_request(:post, 'https://sandbox.plaid.com/transactions/sync').to_return(
      { status: 200, body: page(added: [transaction], more: true).to_json },
      { status: 400, body: { error_code: 'ITEM_LOGIN_REQUIRED', error_message: 'PRIVATE BANK INFORMATION' }.to_json })
    error = assert_raises(BankFeed::PlaidClient::Error) { BankFeed::Sync.call(@connection) }
    assert_not_includes error.message, 'PRIVATE'
    assert_equal 'ITEM_LOGIN_REQUIRED', @connection.reload.last_error_code
    assert_equal 'original', @connection.cursor
    assert_equal 0, BankStatementLine.count
    assert_equal 0, ReconciliationDocument.where(source: 'bank').count
  end

  test 'a later invalid transaction rolls back all earlier database changes' do
    stub_sync(page(added: [transaction]), page(added: [transaction, transaction(id: 'foreign', iso_currency_code: 'EUR')], cursor: 'bad'))
    BankFeed::Sync.call(@connection)
    original_count = ReconciliationDocument.count
    assert_raises(BankFeed::PlaidClient::Error) { BankFeed::Sync.call(@connection) }
    assert_equal 'cursor-1', @connection.reload.cursor
    assert_equal 1, BankStatementLine.count
    assert_equal original_count, ReconciliationDocument.count
  end

  test 'modifications update undecided lines and retain both source revisions' do
    stub_sync(page(added: [transaction]), page(modified: [transaction(amount: 20)], cursor: 'cursor-2'))
    2.times { BankFeed::Sync.call(@connection) }
    assert_equal 1, BankStatementLine.count
    assert_equal(-2000, BankStatementLine.first.amount_cents)
    assert_equal 2, ReconciliationDocument.where(source: 'bank').count
  end

  test 'modifications and removals preserve recorded accounting and flag the line' do
    stub_sync(page(added: [transaction]), page(modified: [transaction(amount: 20)], cursor: 'cursor-2'),
      page(removed: ['txn-1'], cursor: 'cursor-3'))
    BankFeed::Sync.call(@connection)
    line = BankStatementLine.first
    expense = Finance::Expense.create!(payee: 'UPS', category: 'shipping', amount_cents: 1234, incurred_on: line.posted_on)
    line.decide!(status: 'recorded', user: users(:regular_user), expense: expense)
    BankFeed::Sync.call(@connection)
    assert_equal 'changed', line.reload.source_state
    assert_equal(-1234, line.amount_cents)
    assert_equal 2000, BankFeedEntry.first.payload['amount_cents'].abs
    assert_equal 1, BooksCheck.new.checks.find { |check| check.key == 'bank_feed_changes' }.count
    BankFeed::Sync.call(@connection)
    assert_equal 'removed', line.reload.source_state
    assert_equal 'recorded', line.status
    assert_equal 1234, expense.reload.amount_cents
    assert_equal 3, ReconciliationDocument.where(source: 'bank').count
  end

  test 'removed undecided lines are retained as ignored and are not reviewable' do
    stub_sync(page(added: [transaction]), page(removed: ['txn-1'], cursor: 'cursor-2'))
    2.times { BankFeed::Sync.call(@connection) }
    assert_equal 1, BankStatementLine.count
    assert_equal 'ignored', BankStatementLine.first.status
    assert_equal 'removed', BankStatementLine.first.source_state
    assert_equal 0, BankStatementLine.pending.count
  end

  test 'empty initial response is successful and next sync still fetches updates' do
    stub_sync(page, page(added: [transaction], cursor: 'cursor-2'))
    BankFeed::Sync.call(@connection)
    assert @connection.reload.last_synced_at
    assert_equal 0, BankStatementLine.count
    BankFeed::Sync.call(@connection)
    assert_equal 1, BankStatementLine.count
  end

  test 'tenant scopes hide bank secrets entries and lines' do
    stub_sync(page(added: [transaction]))
    BankFeed::Sync.call(@connection)
    Current.tenant = Tenant.create!(id: 'other-bank-tenant', name: 'Other Shop', subdomain: 'other-bank', status: 'active')
    assert_nil BankConnection.find_by(id: @connection.id)
    assert_equal 0, BankFeedEntry.count
    assert_equal 0, BankStatementLine.count
  end

  test 'disabled connections never call Plaid' do
    @connection.update!(sync_enabled: false)
    BankFeed::Sync.call(@connection)
    assert_not_requested(:post, 'https://sandbox.plaid.com/transactions/sync')
  end

  test 'a removed unreviewed transaction can be reinstated without duplicating its line' do
    stub_sync(page(added: [transaction]), page(removed: ['txn-1'], cursor: 'cursor-2'),
      page(added: [transaction(amount: 20)], cursor: 'cursor-3'))
    3.times { BankFeed::Sync.call(@connection) }
    assert_equal 1, BankStatementLine.count
    assert_equal 'pending', BankStatementLine.first.status
    assert_equal 'active', BankStatementLine.first.source_state
    assert_equal(-2000, BankStatementLine.first.amount_cents)
  end

  test 'a connection cannot publish into another workspace' do
    Current.tenant = Tenant.create!(id: 'wrong-bank-tenant', name: 'Other Shop', subdomain: 'wrong-bank', status: 'active')
    error = assert_raises(BankFeed::PlaidClient::Error) { BankFeed::Sync.call(@connection) }
    assert_equal 'WORKSPACE_MISMATCH', error.code
    assert_not_requested(:post, /plaid\.com/)
    assert_nil @connection.reload.last_error_code
  end

  test 'unsupported account types fail without publishing lines' do
    invalid = page(added: [transaction])
    invalid[:accounts].first[:type] = 'credit'
    stub_sync(invalid)
    error = assert_raises(BankFeed::PlaidClient::Error) { BankFeed::Sync.call(@connection) }
    assert_equal 'UNSUPPORTED_ACCOUNT', error.code
    assert_equal 0, BankStatementLine.count
    assert_nil @connection.reload.cursor
  end

  test 'invalid fractional cents fail the batch without rounding bank amounts' do
    stub_sync(page(added: [transaction(amount: 12.345)]))
    error = assert_raises(BankFeed::PlaidClient::Error) { BankFeed::Sync.call(@connection) }
    assert_equal 'INVALID_AMOUNT', error.code
    assert_equal 0, BankStatementLine.count
  end

  test 'locked accounting periods retain the cursor and publish nothing' do
    stub_sync(page(added: [transaction(date: '2026-09-14')]))
    PeriodLock.record!(action: 'lock', kind: 'monthly', date: '2026-09-01', user: users(:regular_user))
    before = ReconciliationDocument.count
    assert_raises(ActiveRecord::RecordInvalid) { BankFeed::Sync.call(@connection) }
    assert_equal 0, BankStatementLine.count
    assert_equal before, ReconciliationDocument.count
    assert_nil @connection.reload.cursor
  end
end
