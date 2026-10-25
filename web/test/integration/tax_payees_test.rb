# frozen_string_literal: true

require 'test_helper'

class TaxPayeesTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    @vendor = Purchasing::Vendor.create!(name: 'Leaf Lawyers LLP')
  end

  teardown { Current.reset }

  def payee(**attributes)
    Finance::TaxPayee.create!({ payee_key: "v:#{@vendor.id}", legal_name: 'Leaf Lawyers LLP', tax_classification: 'partnership',
      form_type: 'misc', misc_box: '10', tin_type: 'ein', tin: '12-3456789' }.merge(attributes))
  end

  test 'the TIN is encrypted, normalized to digits and shown only as its last four' do
    record = payee
    assert_equal '123456789', record.reload.tin
    assert_equal '6789', record.tin_last4
    assert_equal '•••-••-6789', record.masked_tin
    raw = ActiveRecord::Base.connection.select_value("SELECT tin FROM tax_payees WHERE id = #{record.id}")
    refute_includes raw.to_s, '123456789'
  end

  test 'form rules: MISC needs a box, TIN needs 9 digits and a type, corporations are flagged exempt except attorney fees' do
    refute Finance::TaxPayee.new(payee_key: 'p:sam', legal_name: 'Sam', tax_classification: 'individual', form_type: 'misc').valid?
    refute Finance::TaxPayee.new(payee_key: 'p:sam', legal_name: 'Sam', tax_classification: 'individual', form_type: 'nec', tin: '123').valid?
    refute Finance::TaxPayee.new(payee_key: 'p:sam', legal_name: 'Sam', tax_classification: 'individual', form_type: 'nec', tin: '123456789').valid?
    refute Finance::TaxPayee.new(payee_key: 'x:1', legal_name: 'Sam', tax_classification: 'individual', form_type: 'nec').valid?
    nec = Finance::TaxPayee.new(payee_key: 'p:corp', legal_name: 'Corp', tax_classification: 'c_corporation', form_type: 'nec')
    assert nec.likely_exempt?
    refute payee(tax_classification: 'c_corporation').likely_exempt?
    assert_equal %w[W-9 address], payee(payee_key: 'p:other').missing
  end

  test 'admins add and edit payees without the TIN ever reaching the page; blank keeps it' do
    post login_path, params: { email: @admin.email, password: 'password' }
    get new_finance_tax_payee_path
    assert_response :success
    assert_select "option[value='v:#{@vendor.id}']", 'Leaf Lawyers LLP'
    post finance_tax_payees_path, params: { tax_payee: { payee_key: "v:#{@vendor.id}", legal_name: 'Leaf Lawyers LLP', tax_classification: 'partnership',
      form_type: 'misc', misc_box: '10', tin_type: 'ein', tin: '98-7654321', state: 'ny', postal_code: '10001' } }
    assert_redirected_to finance_tax_payees_path
    follow_redirect!
    assert_includes response.body, '•••-••-4321'
    refute_includes response.body, '987654321'
    record = Finance::TaxPayee.last
    assert_equal 'NY', record.state

    get edit_finance_tax_payee_path(record)
    refute_includes response.body, '987654321'
    patch finance_tax_payee_path(record), params: { tax_payee: { legal_name: 'Leaf Lawyers', tin: '' } }
    assert_equal ['Leaf Lawyers', '987654321'], [record.reload.legal_name, record.tin]
    get new_finance_tax_payee_path
    assert_select "option[value='v:#{@vendor.id}']", count: 0
  end

  test 'yearly totals leave out card payments, count paid contractor payslips, and apply the year threshold' do
    lawyer = payee
    Finance::VendorPayment.create!(vendor: @vendor, amount_cents: 1_500_00, paid_on: Date.new(2026, 3, 1), method: 'check')
    Finance::Expense.create!(vendor_id: @vendor.id, amount_cents: 700_00, incurred_on: Date.new(2026, 4, 1), method: 'other', category: 'other')
    Finance::Expense.create!(vendor_id: @vendor.id, amount_cents: 900_00, incurred_on: Date.new(2026, 5, 1), method: 'card', category: 'other')
    Finance::VendorPayment.create!(vendor: @vendor, amount_cents: 5_000_00, paid_on: Date.new(2025, 12, 31), method: 'check')
    cleaner = Finance::TaxPayee.create!(payee_key: 'p:sparkle cleaning', legal_name: 'Sam Sparkle', tax_classification: 'individual', form_type: 'nec')
    Finance::Expense.create!(payee: ' Sparkle Cleaning ', amount_cents: 650_00, incurred_on: Date.new(2026, 6, 1), method: 'cash', category: 'other')

    totals = Finance::Form1099Totals.new(year: 2026)
    row = totals.rows.find { |candidate| candidate.payee == lawyer }
    assert_equal [2_200_00, 900_00, 700_00, 2], [row.paid_cents, row.card_cents, row.other_method_cents, row.count]
    assert_equal 'needed', row.status(2026)
    small = totals.rows.find { |candidate| candidate.payee == cleaner }
    assert_equal [650_00, 'under'], [small.paid_cents, small.status(2026)]
    assert_equal 'needed', Finance::Form1099Totals.new(year: 2025).rows.find { |candidate| candidate.payee == lawyer }.status(2025)
    assert_equal 600_00, Finance::Form1099Totals.threshold_cents(2025, cleaner)

    post login_path, params: { email: @admin.email, password: 'password' }
    get finance_tax_payees_path(year: 2026)
    assert_response :success
    assert_includes response.body, 'Needs a 1099'
    get finance_tax_payees_path(year: 2026, format: :csv)
    assert_includes response.body, '2200.00'
    assert_includes response.body, '•••-••-6789'
    refute_includes response.body, '123456789'
  end

  test 'recipient copies need payer details, then print each payee who needs a 1099 with the TIN truncated' do
    payee
    Finance::VendorPayment.create!(vendor: @vendor, amount_cents: 2_500_00, paid_on: Date.new(2026, 3, 1), method: 'check')
    post login_path, params: { email: @admin.email, password: 'password' }
    get forms_finance_tax_payees_path(year: 2026)
    assert_redirected_to payer_finance_tax_payees_path

    patch payer_finance_tax_payees_path, params: { tax_payer: { name: 'Rupert Test Shop LLC', street: '1 Main St', city: 'Albany', state: 'ny', zip: '12207', tin: '12-3456789' } }
    assert_redirected_to finance_tax_payees_path
    assert_equal ['NY', '123456789'], [Finance::TaxPayer.load.state, Finance::TaxPayer.load.tin]
    get payer_finance_tax_payees_path
    refute_includes response.body, '123456789'
    patch payer_finance_tax_payees_path, params: { tax_payer: { name: 'Rupert Test Shop LLC', street: '1 Main St', city: 'Albany', state: 'NY', zip: '12207', tin: '' } }
    assert_equal '123456789', Finance::TaxPayer.load.tin

    get forms_finance_tax_payees_path(year: 2026)
    assert_response :success
    assert_equal 'application/pdf', response.media_type
    text = pdf_text(response.body)
    assert_includes text, 'Copy B'
    assert_includes text, 'XXX-XX-6789'
    assert_includes text, '$2,500.00'
    assert_includes text, '12-3456789'
    refute_includes text, '123456789'
  ensure
    Finance::TaxPayer::FIELDS.each_value { |key| EnvStore.set(key, nil) }
  end

  test 'managers and cashiers cannot open 1099 payees' do
    payee
    %w[manager cashier].each do |role|
      user = User.create!(tenant: Current.tenant, email: "tax-#{role}@example.com", role: role, password: 'password123')
      post login_path, params: { email: user.email, password: 'password123' }
      get finance_tax_payees_path
      assert_includes [302, 303, 403], response.status, role
      delete logout_path
    end
  end

  test 'issuing a year snapshots each 1099 with who and when, once, and the recipient copies print the issued totals' do
    lawyer = payee
    Finance::VendorPayment.create!(vendor: @vendor, amount_cents: 2_500_00, paid_on: Date.new(2026, 3, 1), method: 'check')
    with_payer do
      post login_path, params: { email: @admin.email, password: 'password' }
      get finance_tax_payees_path(year: 2026)
      assert_includes response.body, 'Not issued'
      assert_select 'button', text: 'Issue 1 1099 for 2026'

      assert_difference -> { Finance::TaxFormFiling.count }, 1 do
        post issue_finance_tax_payees_path(year: 2026)
      end
      assert_redirected_to finance_tax_payees_path(year: 2026)
      filing = Finance::TaxFormFiling.last
      assert_equal [lawyer.id, 2026, 'original', 'misc', '10', 2_500_00, '6789', @admin.id],
        [filing.tax_payee_id, filing.tax_year, filing.kind, filing.form_type, filing.misc_box, filing.paid_cents, filing.tin_last4, filing.issued_by_id]
      assert filing.issued_at.present?
      assert ActivityLog.exists?(action: 'tax_form_issued', subject_id: lawyer.id.to_s)

      assert_no_difference -> { Finance::TaxFormFiling.count } do
        post issue_finance_tax_payees_path(year: 2026)
      end
      get finance_tax_payees_path(year: 2026)
      assert_includes response.body, 'Locked'
      assert_includes response.body, 'Issued'
      assert_raises(ActiveRecord::ReadOnlyRecord) { filing.reload.update!(paid_cents: 1) }
      assert_raises(ActiveRecord::ReadOnlyRecord) { filing.destroy }
    end
  end

  test 'a late payment after issue shows the difference, and a corrected form is marked and kept beside the original' do
    lawyer = payee
    Finance::VendorPayment.create!(vendor: @vendor, amount_cents: 2_500_00, paid_on: Date.new(2026, 3, 1), method: 'check')
    with_payer do
      post login_path, params: { email: @admin.email, password: 'password' }
      post issue_finance_tax_payees_path(year: 2026)
      original = Finance::TaxFormFiling.last
      Finance::VendorPayment.create!(vendor: @vendor, amount_cents: 300_00, paid_on: Date.new(2026, 11, 1), method: 'check')

      get finance_tax_payees_path(year: 2026)
      assert_select 'span.pill-clay', text: 'Needs correction'
      assert_includes response.body, '+$300.00'
      text = pdf_text(get_pdf(forms_finance_tax_payees_path(year: 2026)))
      assert_includes text, '$2,500.00'
      refute_includes text, '$2,800.00'
      refute_includes text, '2026 · CORRECTED'
      assert_includes text, 'CORRECTED (if checked)'

      assert_difference -> { Finance::TaxFormFiling.count }, 1 do
        post correct_finance_tax_payee_path(lawyer, year: 2026)
      end
      corrected = Finance::TaxFormFiling.last
      assert_redirected_to form_finance_tax_payee_path(lawyer, filing: corrected.id)
      assert_equal 'corrected', corrected.kind
      assert_equal 2_800_00, corrected.paid_cents
      assert_equal 2_500_00, original.reload.paid_cents
      assert ActivityLog.exists?(action: 'tax_form_corrected', subject_id: lawyer.id.to_s)

      follow_redirect!
      text = pdf_text(response.body)
      assert_includes text, 'Form 1099-MISC · 2026 · CORRECTED'
      assert_includes text, '$2,800.00'
      assert_includes text, 'XXX-XX-6789'
      refute_includes text, '123456789'
      assert_includes pdf_text(get_pdf(form_finance_tax_payee_path(lawyer, filing: original.id))), '$2,500.00'

      get finance_tax_payees_path(year: 2026)
      assert_select 'span.pill-fern', text: 'Corrected'
      assert_select 'span.pill-clay', text: 'Needs correction', count: 0
      assert_no_difference -> { Finance::TaxFormFiling.count } do
        post correct_finance_tax_payee_path(lawyer, year: 2026)
      end
      assert_includes pdf_text(get_pdf(forms_finance_tax_payees_path(year: 2026))), '2026 · CORRECTED'
    end
  end

  test 'managers and cashiers cannot issue, correct or download issued 1099s' do
    lawyer = payee
    Finance::VendorPayment.create!(vendor: @vendor, amount_cents: 2_500_00, paid_on: Date.new(2026, 3, 1), method: 'check')
    filing = Finance::TaxFormFiling.issue!(Finance::Form1099Totals.new(year: 2026).needed.first, year: 2026, kind: 'original', by: @admin)
    Finance::VendorPayment.create!(vendor: @vendor, amount_cents: 300_00, paid_on: Date.new(2026, 11, 1), method: 'check')
    with_payer do
      %w[manager cashier].each do |role|
        user = User.create!(tenant: Current.tenant, email: "tax-lock-#{role}@example.com", role: role, password: 'password123')
        post login_path, params: { email: user.email, password: 'password123' }
        assert_no_difference -> { Finance::TaxFormFiling.count } do
          post issue_finance_tax_payees_path(year: 2026)
          assert_includes [302, 303, 403], response.status, role
          post correct_finance_tax_payee_path(lawyer, year: 2026)
          assert_includes [302, 303, 403], response.status, role
        end
        get form_finance_tax_payee_path(lawyer, filing: filing.id)
        assert_includes [302, 303, 403], response.status, role
        refute_equal 'application/pdf', response.media_type
        delete logout_path
      end
    end
  end

  test 'issued 1099s stay inside their workspace' do
    lawyer = payee
    Finance::VendorPayment.create!(vendor: @vendor, amount_cents: 2_500_00, paid_on: Date.new(2026, 3, 1), method: 'check')
    other = Tenant.create!(name: 'Other Co', subdomain: 'other-1099')
    Current.tenant = other
    vendor = Purchasing::Vendor.create!(name: 'Other Vendor')
    stranger = Finance::TaxPayee.create!(payee_key: "v:#{vendor.id}", legal_name: 'Other Vendor', tax_classification: 'individual', form_type: 'nec')
    Finance::VendorPayment.create!(vendor: vendor, amount_cents: 9_000_00, paid_on: Date.new(2026, 3, 1), method: 'check')
    foreign = Finance::TaxFormFiling.issue!(Finance::Form1099Totals.new(year: 2026).needed.first, year: 2026, kind: 'original')
    assert_equal other.id, foreign.tenant_id
    Current.tenant = tenants(:default_tenant)

    lock = Finance::Form1099Lock.new(Finance::Form1099Totals.new(year: 2026))
    refute lock.issued?
    assert_equal [lawyer], lock.not_issued.map { |entry| entry.row.payee }
    assert_raises(ActiveRecord::RecordInvalid) do
      Finance::TaxFormFiling.create!(tax_payee: stranger, tax_year: 2026, kind: 'original', form_type: 'nec', paid_cents: 1,
        legal_name: 'x', issued_at: Time.current)
    end
    with_payer do
      post login_path, params: { email: @admin.email, password: 'password' }
      post issue_finance_tax_payees_path(year: 2026)
      assert_equal [lawyer.id], Finance::TaxFormFiling.pluck(:tax_payee_id)
      get form_finance_tax_payee_path(stranger, filing: foreign.id)
      assert_response :not_found
      get form_finance_tax_payee_path(lawyer, filing: foreign.id)
      assert_response :not_found
      post correct_finance_tax_payee_path(stranger, year: 2026)
      assert_response :not_found
      assert_equal 1, Finance::TaxFormFiling.unscoped.where(tenant_id: other.id).count
    end
  end

  private

  def with_payer
    Finance::TaxPayer.new.update(name: 'Rupert Test Shop LLC', street: '1 Main St', city: 'Albany', state: 'NY', zip: '12207', tin: '12-3456789')
    yield
  ensure
    Finance::TaxPayer::FIELDS.each_value { |key| EnvStore.set(key, nil) }
  end

  def get_pdf(path)
    get path
    assert_equal 'application/pdf', response.media_type
    response.body
  end

  # Prawn's text operators, decoded (as in the stock comparison PDF test).
  def pdf_text(body)
    content = body.b.scan(/stream\r?\n(.*?)\nendstream/m).flatten.map do |stream|
      Zlib::Inflate.inflate(stream)
    rescue Zlib::Error
      stream
    end.join("\n")
    content.scan(/\[([^\]]*)\]\s*TJ|<(\h*)>\s*Tj/).map do |array, single|
      (single ? [single] : array.scan(/<(\h*)>/).flatten).map { |hex| [hex].pack('H*') }.join
    end.join("\n").force_encoding('Windows-1252').encode('UTF-8')
  end
end
