# frozen_string_literal: true

require 'test_helper'

# SwipeSimple CSV import: parses the export, feeds the canonical sales stream
# (orders + lines + payments + ledger), and stays idempotent on re-import.
class SwipesimpleImportTest < ActionDispatch::IntegrationTest
  module TestShopifySession
    def current_shopify_session
      @test_session ||= ShopifyAPI::Auth::Session.new(
        shop: 'm11u0i-sb.myshopify.com',
        access_token: 'test-token',
        is_online: false,
        expires: Time.now + 3600
      )
    end
  end

  ShopifyApp::TokenExchange.prepend(TestShopifySession)

  setup do
    ShopifyAPI::Context.setup(
      api_key: 'test-key',
      api_secret_key: 'test-secret',
      api_version: ShopifyAPI::AdminVersions::SUPPORTED_ADMIN_VERSIONS.first,
      host_name: 'localhost',
      scope: 'read_products',
      is_private: false,
      is_embedded: false
    )
    Shop.create!(shopify_domain: 'm11u0i-sb.myshopify.com', shopify_token: 'test-token')

    @tenant = Tenant.create!(name: 'Test Co', subdomain: 'testco')
    @user = User.create!(email: 'sync@example.com', password: 'password123', role: 'admin', tenant_id: @tenant.id,
                         name: 'Sync')
    post login_path, params: { email: 'sync@example.com', password: 'password123' }
    Current.tenant = @tenant
  end

  teardown do
    Current.tenant = nil
  end

  CSV_TEXT = <<~CSV
    Order,Date,Item,SKU,Qty,Unit Price,Total,Payment,Customer
    1001,07/01/2026,Honey Sticks,TEA-50,2,14.00,28.00,Card,Alex Morgan
    1001,07/01/2026,Peppermint Oil,OIL-3,1,12.50,12.50,Card,Alex Morgan
    1002,7/2/2026,CBD Gummies,GUM-1,1,$9.99,$9.99,Cash,Jamie Rivera
  CSV

  test 'importer handles a line-level export with flexible columns' do
    result = SyncEngine.import_swipesimple_csv!(CSV_TEXT, actor: 'test')

    assert_equal 2, result.orders
    assert_equal 3, result.lines
    assert_equal 0, result.skipped_rows

    order = Core::Order.find_by!(source: 'swipesimple', source_order_id: '1001')
    assert_equal 'paid', order.status
    assert_equal 4050, order.gross_cents # 28.00 + 12.50
    assert_equal 2, order.order_lines.count
    assert_equal 1400, order.order_lines.find_by(sku: 'TEA-50').unit_cents
    assert_equal 2800, order.order_lines.find_by(sku: 'TEA-50').line_cents
    assert_equal 1, order.payments.count
    assert_equal 'card', order.payments.first.method
    assert_equal 4050, order.payments.first.amount_cents

    order2 = Core::Order.find_by!(source: 'swipesimple', source_order_id: '1002')
    assert_equal 999, order2.gross_cents # $9.99
    assert_equal 'cash', order2.payments.first.method

    assert_equal 'SS-1001', order.display_number
    assert LedgerEntry.exists?(id: 'swipesimple:1001')
    assert LedgerEntry.exists?(id: 'swipesimple:1002')
    run = SyncRun.find_by!(source: 'swipesimple', mode: 'csv')
    assert run.success?
  end

  test 're-importing the same file is idempotent' do
    SyncEngine.import_swipesimple_csv!(CSV_TEXT, actor: 'test')
    SyncEngine.import_swipesimple_csv!(CSV_TEXT, actor: 'test')

    assert_equal 2, Core::Order.where(source: 'swipesimple').count
    assert_equal 3, Core::Order.where(source: 'swipesimple').sum(:line_items)
    assert_equal 2, LedgerEntry.where(source: 'swipesimple').count
  end

  test 'rows without an order id become stable single-item orders' do
    csv = "Date,Item,Price\n2026-07-05,Tea,5.00\n2026-07-06,Coffee,3.00\n"
    SyncEngine.import_swipesimple_csv!(csv, actor: 'test')

    orders = Core::Order.where(source: 'swipesimple')
    assert_equal 2, orders.count
    assert_equal [300, 500], orders.map(&:gross_cents).sort

    SyncEngine.import_swipesimple_csv!(csv, actor: 'test')
    assert_equal 2, Core::Order.where(source: 'swipesimple').count # idempotent
  end

  test 'controller imports an uploaded CSV and redirects with a summary' do
    file = Tempfile.new(['swipesimple', '.csv'])
    file.write(CSV_TEXT)
    file.rewind

    post(import_swipesimple_syncs_path, params: {
           file: Rack::Test::UploadedFile.new(file.path, 'text/csv'),
           shop: 'm11u0i-sb.myshopify.com',
           embedded: '1',
           host: 'test-host'
         })
    follow_redirect!
    assert_response(:success)
    assert_match(/Imported 2 order\(s\), 3 line\(s\)/, flash[:notice])
    assert_equal(2, Core::Order.where(source: 'swipesimple').count)
  ensure
    file&.close
    file&.unlink
  end

  test 'a reader cannot upload a SwipeSimple import' do
    User.create!(email: 'reader2@example.com', password: 'password123', role: 'reader', tenant_id: @tenant.id,
                 name: 'Reader')
    delete logout_path
    post login_path, params: { email: 'reader2@example.com', password: 'password123' }

    post import_swipesimple_syncs_path, params: {
      text: CSV_TEXT,
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1',
      host: 'test-host'
    }
    follow_redirect!
    assert_match(/don't have permission/, flash[:alert])
    assert_equal 0, Core::Order.where(source: 'swipesimple').count
  end
end
