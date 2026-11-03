# frozen_string_literal: true

require 'test_helper'

class CustomerWholesaleTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @retail = Core::Customer.create!(source: 'manual', external_id: 'retail-1', first_name: 'Rita', last_name: 'Retail')
    @synced = Core::Customer.create!(source: 'shopify', external_id: 'gid://shopify/Customer/77', first_name: 'Wanda',
      last_name: 'Shop', email: 'wanda@example.test', source_synced_at: 1.day.ago)
    post login_path, params: { email: @user.email, password: 'password' }
  end

  teardown { Current.reset }

  def mark_wholesale(customer, **extra)
    patch customer_path(customer), params: { customer: { wholesale: '1', wholesale_business_name: 'Green Leaf Co-op',
      resale_certificate_number: 'RC-12345', resale_certificate_expires_on: '2027-06-30', wholesale_notes: 'Net 30' }.merge(extra) }
  end

  test 'staff mark and unmark a synced customer as wholesale, and each change is in the Activity log without values' do
    get edit_customer_path(@synced)
    assert_select 'fieldset#wholesale legend', 'Wholesale'
    assert_select 'input[type=checkbox][name="customer[wholesale]"]'

    mark_wholesale(@synced)
    assert_redirected_to customer_path(@synced)
    @synced.reload
    assert @synced.wholesale?
    assert_equal 'Green Leaf Co-op', @synced.wholesale_business_name
    assert_equal 'RC-12345', @synced.resale_certificate_number
    assert_equal Date.new(2027, 6, 30), @synced.resale_certificate_expires_on
    assert_equal 'Net 30', @synced.wholesale_notes
    # Contact details stay owned by the source.
    assert_equal 'wanda@example.test', @synced.email

    marked = ActivityLog.where(action: 'customer_marked_wholesale').sole
    assert_equal "Customer ##{@synced.id}", marked.subject_label
    assert_match(/wholesale_business_name/, marked.details)
    refute_match(/RC-12345|Green Leaf|Net 30/, marked.details)

    patch customer_path(@synced), params: { customer: { wholesale: '0' } }
    refute @synced.reload.wholesale?
    # Details are kept so re-marking the account restores them.
    assert_equal 'RC-12345', @synced.resale_certificate_number
    assert_equal 1, ActivityLog.where(action: 'customer_unmarked_wholesale').count

    patch customer_path(@synced), params: { customer: { notes: 'Plain edit' } }
    assert_equal 1, ActivityLog.where(action: 'customer_updated').count
  end

  test 'a new manual customer can be added as wholesale' do
    post customers_path, params: { customer: { first_name: 'Bulk', last_name: 'Buyer', wholesale: '1', wholesale_business_name: 'Bulk Buyer LLC' } }
    record = Core::Customer.order(:id).last
    assert record.wholesale?
    assert_equal 'manual profile, wholesale', ActivityLog.find_by!(action: 'customer_created').details
  end

  test 'wholesale details are validated' do
    mark_wholesale(@retail, wholesale_business_name: 'x' * 256)
    assert_response :unprocessable_entity
    assert_select '[role=alert] li', /Wholesale business name/
    refute @retail.reload.wholesale?
  end

  test 'list shows the pill, filters All, Retail and Wholesale, and counts them' do
    @synced.update!(wholesale: true, wholesale_business_name: 'Green Leaf Co-op')

    get customers_path
    assert_response :success
    assert_select 'tbody tr', 2
    assert_select 'tbody tr span.pill-olive', text: 'Wholesale', count: 1
    assert_select 'ul[aria-label="Customer list"] span.pill-olive', text: 'Wholesale', count: 1
    assert_select 'tbody tr', text: /Green Leaf Co-op/
    assert_select 'select#account option[value=""]', text: 'All accounts · 2'
    assert_select 'select#account option[value="retail"]', text: 'Retail · 1'
    assert_select 'select#account option[value="wholesale"]', text: 'Wholesale · 1'
    assert_select 'a[href=?] .stat-value', customers_path(account: 'wholesale'), text: '1'

    get customers_path(account: 'wholesale')
    assert_select 'tbody tr', 1
    assert_select 'tbody tr', text: /Wanda Shop/
    assert_select 'ul[aria-label="Active filters"] a', text: /Account: Wholesale/

    get customers_path(account: 'retail')
    assert_select 'tbody tr', 1
    assert_select 'tbody tr', text: /Rita Retail/
    assert_select 'tbody tr span.pill-olive', text: 'Wholesale', count: 0

    get customers_path(account: 'bogus')
    assert_select 'tbody tr', 2

    get export_customers_path(account: 'wholesale')
    rows = CSV.parse(response.body, headers: true)
    assert_equal [['true', 'Green Leaf Co-op']], rows.map { |row| [row['wholesale'], row['wholesale_business_name']] }
  end

  test 'detail page shows the account, business details and an expired certificate' do
    get customer_path(@retail)
    assert_select '.facts dd', text: 'Retail'
    assert_select 'section[aria-label="Wholesale account"]', count: 0

    @retail.update!(wholesale: true, wholesale_business_name: 'Rita Wholesale', resale_certificate_number: 'RC-1',
      resale_certificate_expires_on: Date.current - 1)
    get customer_path(@retail)
    assert_select '.facts span.pill-olive', 'Wholesale'
    assert_select '.facts span.pill-clay', 'Certificate expired'
    assert_select 'section[aria-label="Wholesale account"]' do
      assert_select 'dd', text: 'Rita Wholesale'
      assert_select 'dd', text: 'RC-1'
      assert_select 'a[href=?]', edit_customer_path(@retail, anchor: 'wholesale')
    end
  end

  test 'readers see wholesale customers but cannot mark or unmark them' do
    @synced.update!(wholesale: true)
    @user.update!(role: 'reader')

    get customer_path(@synced)
    assert_response :success
    assert_select '.facts span.pill-olive', 'Wholesale'
    assert_select 'a[href=?]', edit_customer_path(@synced, anchor: 'wholesale'), count: 0

    patch customer_path(@synced), params: { customer: { wholesale: '0' } }
    assert_response :redirect
    assert @synced.reload.wholesale?
    mark_wholesale(@retail)
    refute @retail.reload.wholesale?
    assert_equal 0, ActivityLog.where(action: %w[customer_marked_wholesale customer_unmarked_wholesale]).count
  end

  test 'orders, printed invoices and search show the wholesale pill' do
    @synced.update!(wholesale: true, wholesale_business_name: 'Green Leaf Co-op')
    order = Core::Order.new(source: 'shopify', source_order_id: 'gid://shopify/Order/5', order_number: '#5005', occurred_at: Time.current,
      gross_cents: 1_000, currency: 'USD', customer_id: @synced.id)
    order.aasm.current_state = :paid
    order.save!

    get order_path(order)
    assert_response :success
    assert_select 'span.pill-olive', 'Wholesale'
    assert_includes response.body, 'Green Leaf Co-op'

    get sales_print_path(date: Date.current.iso8601, doc: 'invoice')
    assert_response :success
    assert_select 'span.pill-olive', 'Wholesale'

    get search_path(q: 'Wanda')
    assert_response :success
    assert_includes response.body, 'Wholesale · wanda@example.test'
  end
end
