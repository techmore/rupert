# frozen_string_literal: true

require 'test_helper'
require 'csv'

# The IRS IRIS upload files for 1099-NEC and 1099-MISC (#472), from the forms as issued.
class TaxIrisCsvTest < ActionDispatch::IntegrationTest
  FIXTURES = Rails.root.join('test/fixtures/files/iris')

  setup do
    Current.tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    @vendor = Purchasing::Vendor.create!(name: 'Leaf Lawyers LLP')
    @lawyer = Finance::TaxPayee.create!(payee_key: "v:#{@vendor.id}", legal_name: 'Leaf Lawyers, L.L.P.', business_name: 'Leaf & Branch Law',
      tax_classification: 'partnership', form_type: 'misc', misc_box: '10', tin_type: 'ein', tin: '98-7654321',
      address_line1: '200 Court St., Suite #4', city: 'Troy', state: 'NY', postal_code: '12180-1234', w9_received_on: Date.new(2026, 1, 5))
    @cleaner = Finance::TaxPayee.create!(payee_key: 'p:sparkle cleaning', legal_name: 'Sam Quinn Sparkle Jr', tax_classification: 'individual',
      form_type: 'nec', tin_type: 'ssn', tin: '123-45-6789', address_line1: '12 Elm St.', address_line2: 'Apt #3', city: 'Saratoga Springs',
      state: 'NY', postal_code: '12866', w9_received_on: Date.new(2026, 1, 5))
    Finance::VendorPayment.create!(vendor: @vendor, amount_cents: 2_500_00, paid_on: Date.new(2026, 3, 1), method: 'check')
    Finance::Expense.create!(payee: 'Sparkle Cleaning', amount_cents: 3_210_55, incurred_on: Date.new(2026, 6, 1), method: 'cash', category: 'other')
  end

  teardown do
    Finance::TaxPayer::FIELDS.each_value { |key| EnvStore.set(key, nil) }
    Current.reset
  end

  test 'columns follow the IRS tax year 2025 template guidelines in order, for both forms' do
    { 'nec' => '1099_nec_ty2025_columns.txt', 'misc' => '1099_misc_ty2025_columns.txt' }.each do |form, file|
      expected = fixture_columns(file)
      assert_equal expected.values, Finance::IrisCsv::COLUMNS.fetch(form), form
    end
    assert_equal 54, Finance::IrisCsv::COLUMNS['nec'].size
    assert_equal 64, Finance::IrisCsv::COLUMNS['misc'].size
  end

  test 'refused until the year is issued and the payer details are complete' do
    login(@admin)
    get iris_finance_tax_payees_path(year: 2026, form: 'nec')
    assert_redirected_to payer_finance_tax_payees_path

    payer!
    get iris_finance_tax_payees_path(year: 2026, form: 'nec')
    assert_redirected_to finance_tax_payees_path(year: 2026)
    assert_match(/Issue the 2026 1099s first/, flash[:alert])
    refute ActivityLog.exists?(action: 'tax_iris_exported')

    get finance_tax_payees_path(year: 2026)
    assert_select 'a', text: /Download IRIS CSV/, count: 0
  end

  test 'the NEC and MISC files carry the issued forms in the IRIS formats, with full TINs, no-store and an activity log' do
    payer!
    login(@admin)
    post issue_finance_tax_payees_path(year: 2026)
    assert_equal 2, Finance::TaxFormFiling.count

    get finance_tax_payees_path(year: 2026)
    assert_select 'a[href=?]', iris_finance_tax_payees_path(year: 2026, form: 'nec'), text: 'Download IRIS CSV · 1099-NEC'
    assert_select 'a[href=?]', iris_finance_tax_payees_path(year: 2026, form: 'misc'), text: 'Download IRIS CSV · 1099-MISC'
    refute_includes response.body, '123456789'
    refute_includes response.body, '123-45-6789'

    nec = download(:nec)
    assert_equal 'attachment; filename="iris-1099-nec-2026.csv"; filename*=UTF-8\'\'iris-1099-nec-2026.csv', response.headers['Content-Disposition']
    assert_includes response.headers['Cache-Control'], 'no-store'
    assert_equal fixture_columns('1099_nec_ty2025_columns.txt').values, nec.headers
    assert_equal 1, nec.size
    row = cells(nec.first, '1099_nec_ty2025_columns.txt')
    assert_equal({ 'A' => '1099-NEC', 'B' => '2026', 'C' => 'EIN', 'D' => '12-3456789', 'E' => 'B', 'F' => 'Rupert Test Shop LLC', 'L' => 'US',
                   'M' => '1 Main St', 'O' => 'Albany', 'P' => 'NY', 'Q' => '12207', 'R' => 'D', 'S' => '5185550100',
                   'T' => 'SSN', 'U' => '123-45-6789', 'V' => 'I', 'Y' => 'Sam', 'Z' => 'Quinn', 'AA' => 'Sparkle', 'AB' => 'Jr', 'AC' => 'US',
                   'AD' => '12 Elm St', 'AE' => 'Apt 3', 'AF' => 'Saratoga Springs', 'AG' => 'NY', 'AH' => '12866',
                   'AK' => 'N', 'AL' => '3210.55', 'AM' => 'N' }, row.compact)
    assert ActivityLog.exists?(action: 'tax_iris_exported', details: 'IRIS CSV 2026 1099-NEC: 1 form')

    misc = download(:misc)
    assert_equal fixture_columns('1099_misc_ty2025_columns.txt').values, misc.headers
    row = cells(misc.first, '1099_misc_ty2025_columns.txt')
    assert_equal({ 'A' => '1099-MISC', 'T' => 'EIN', 'U' => '98-7654321', 'V' => 'B', 'W' => 'Leaf Lawyers LLP', 'X' => 'Leaf & Branch Law',
                   'AD' => '200 Court St Suite 4', 'AF' => 'Troy', 'AH' => '121801234', 'AK' => 'N', 'AL' => 'N', 'AS' => 'N', 'AV' => '2500.00' },
      row.slice('A', 'T', 'U', 'V', 'W', 'X', 'AD', 'AF', 'AH', 'AK', 'AL', 'AS', 'AV'))
    assert_nil row['AM'], 'other boxes stay blank, not zero'
    assert_nil row['Y']
  end

  test 'a corrected form stays out of the upload file and is listed for Make a Correction instead' do
    payer!
    login(@admin)
    post issue_finance_tax_payees_path(year: 2026)
    Finance::VendorPayment.create!(vendor: @vendor, amount_cents: 300_00, paid_on: Date.new(2026, 11, 1), method: 'check')
    post correct_finance_tax_payee_path(@lawyer, year: 2026)
    assert_equal 'corrected', Finance::TaxFormFiling.last.kind

    misc = download(:misc)
    assert_equal 1, misc.size
    assert_equal '2500.00', cells(misc.first, '1099_misc_ty2025_columns.txt')['AV']
    refute_includes misc.to_s, '2800.00'

    export = Finance::IrisCsv.new(year: 2026, form_type: 'misc')
    assert_equal [2_800_00], export.corrections.map { |correction| correction.filing.paid_cents }
    assert_equal 2_500_00, export.corrections.first.previous.paid_cents
    refute export.corrections.first.two_step?
    assert_empty Finance::IrisCsv.new(year: 2026, form_type: 'nec').corrections

    get finance_tax_payees_path(year: 2026)
    assert_select '[aria-label="Corrections to file in IRIS"] li', 1
    assert_select '[aria-label="Corrections to file in IRIS"]', text: /Make a Correction.*\$2,800\.00 \(was \$2,500\.00\)/m
  end

  test 'a record IRIS would reject stops the file and says why' do
    payer!
    login(@admin)
    post issue_finance_tax_payees_path(year: 2026)
    @cleaner.update!(address_line1: nil)
    get iris_finance_tax_payees_path(year: 2026, form: 'nec')
    assert_redirected_to finance_tax_payees_path(year: 2026)
    assert_match(/Sam Quinn Sparkle Jr: no address on file/, flash[:alert])
    refute ActivityLog.exists?(action: 'tax_iris_exported')
  end

  test 'people with tax.read only, managers and cashiers cannot download the IRIS file' do
    payer!
    Finance::Form1099Lock.new(Finance::Form1099Totals.new(year: 2026)).issue!(by: @admin)
    reader = User.create!(tenant: Current.tenant, email: 'tax-reader@example.com', role: 'manager', password: 'password123')
    reader.update_permission_overrides!(['tax.read'])
    assert reader.reload.can?('tax.read')
    refute reader.can?('tax.write')
    users = [reader] + %w[manager cashier].map { |role| User.create!(tenant: Current.tenant, email: "iris-#{role}@example.com", role: role, password: 'password123') }
    users.each do |user|
      login(user, 'password123')
      get iris_finance_tax_payees_path(year: 2026, form: 'nec')
      assert_includes [302, 303, 403], response.status, user.email
      refute_equal 'text/csv', response.media_type
      refute_includes response.body, '123-45-6789'
      delete logout_path
    end

    login(reader, 'password123')
    get finance_tax_payees_path(year: 2026)
    assert_response :success
    assert_select 'a', text: /Download IRIS CSV/, count: 0
    refute ActivityLog.exists?(action: 'tax_iris_exported')
  end

  test 'the file holds only this workspace’s issued forms' do
    payer!
    Finance::Form1099Lock.new(Finance::Form1099Totals.new(year: 2026)).issue!(by: @admin)
    other = Tenant.create!(name: 'Other Co', subdomain: 'other-iris')
    Current.tenant = other
    vendor = Purchasing::Vendor.create!(name: 'Other Vendor')
    Finance::TaxPayee.create!(payee_key: "v:#{vendor.id}", legal_name: 'Olive Other', tax_classification: 'individual', form_type: 'nec',
      tin_type: 'ssn', tin: '555-66-7777', address_line1: '9 Far Rd', city: 'Elsewhere', state: 'CA', postal_code: '90001')
    Finance::VendorPayment.create!(vendor: vendor, amount_cents: 9_000_00, paid_on: Date.new(2026, 3, 1), method: 'check')
    Finance::Form1099Lock.new(Finance::Form1099Totals.new(year: 2026)).issue!
    assert_equal 1, Finance::TaxFormFiling.count
    Current.tenant = tenants(:default_tenant)

    login(@admin)
    nec = download(:nec)
    assert_equal ['Sam'], nec.map { |row| row['Recipient First Name'] }
    refute_includes nec.to_s, '555-66-7777'
    refute_includes nec.to_s, 'Olive'
  end

  test 'the full TIN never reaches the logs or the activity log' do
    payer!
    login(@admin)
    post issue_finance_tax_payees_path(year: 2026)
    log = Rails.root.join('log/test.log')
    before = File.exist?(log) ? File.size(log) : 0
    body = download(:nec).to_s + download(:misc).to_s
    assert_includes body, '123-45-6789'
    assert_includes body, '98-7654321'
    Rails.logger.flush if Rails.logger.respond_to?(:flush)
    written = File.exist?(log) ? File.binread(log, nil, before) : ''
    %w[123-45-6789 123456789 98-7654321 987654321].each do |tin|
      refute_includes written, tin
      refute ActivityLog.where('details LIKE ? OR subject_label LIKE ?', "%#{tin}%", "%#{tin}%").exists?, tin
    end
    assert_equal 2, ActivityLog.where(action: 'tax_iris_exported').count
  end

  private

  def payer!
    Finance::TaxPayer.new.update(name: 'Rupert Test Shop LLC', street: '1 Main St', city: 'Albany', state: 'NY', zip: '12207',
      phone: '(518) 555-0100', tin: '12-3456789')
  end

  def login(user, password = 'password')
    post login_path, params: { email: user.email, password: password }
  end

  def download(form)
    get iris_finance_tax_payees_path(year: 2026, form: form)
    assert_response :success
    assert_equal 'text/csv', response.media_type
    CSV.parse(response.body, headers: true)
  end

  # Column letter => header, from the fixture transcribed from the IRS guidelines.
  def fixture_columns(file)
    File.readlines(FIXTURES.join(file), chomp: true).reject { |line| line.start_with?('#') }.to_h { |line| line.split("\t", 2) }
  end

  def cells(row, file) = fixture_columns(file).keys.zip(row.fields).to_h
end
