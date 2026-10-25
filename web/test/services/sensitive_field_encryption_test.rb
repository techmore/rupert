# frozen_string_literal: true

require 'test_helper'
require 'rake'

# #421: chat, payroll, HR and 1099 fields are ciphertext on disk, read back as plaintext, and rows written before
# the change are rewritten only by the guarded backfill.
class SensitiveFieldEncryptionTest < ActiveSupport::TestCase
  PNG = "\x89PNG\r\n\x1a\n#{'0' * 20}".b

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @user = users(:regular_user)
  end

  teardown { Current.reset }

  def raw(model, id, column)
    model.connection.select_value("SELECT CAST(#{column} AS TEXT) FROM #{model.table_name} WHERE id = #{id.to_i}")
  end

  def ciphertext?(model, id, column) = raw(model, id, column).to_s.start_with?('{"p":')

  # One row of every covered model, in the current tenant.
  def build_rows(tag)
    employee = People::Employee.create!(first_name: 'Ana', last_name: tag, employee_number: "E-#{tag}", address: "1 #{tag} Street",
      date_of_birth: Date.new(1990, 4, 5))
    rate = People::PayRate.create!(employee: employee, pay_type: 'hourly', hourly_rate_cents: 2_150, effective_on: '2026-01-01')
    run = People::PayRun.create!(name: "Run #{tag}", period_start: '2026-07-01', period_end: '2026-07-14', notes: "run note #{tag}")
    slip = run.payslips.create!(employee: employee, pay_rate: rate, hours: 40.5, gross_cents: 87_075, deductions_cents: 13_061,
      net_cents: 74_014, notes: "slip note #{tag}")
    room = TeamChat::Room.create!(name: "room-#{tag.downcase}", slug: "room-#{tag.downcase}", kind: 'channel', created_by: @user)
    message = room.messages.create!(user: @user, body: "secret plan #{tag}")
    file = TeamChat::Attachment.create!(room: room, message: message, filename: 'shelf.png', content_type: 'image/png', byte_size: PNG.bytesize, data: PNG)
    feedback = AgentFeedback.create!(kind: 'bug', summary: 'Broken', source: 'app')
    log = FeedbackAttachment.create!(agent_feedback: feedback, kind: 'server_log', text_body: "log #{tag}")
    payee = Finance::TaxPayee.create!(payee_key: "p:#{tag.downcase}", legal_name: "Pat #{tag}", tax_classification: 'individual',
      form_type: 'nec', tin_type: 'ssn', tin: '123-45-6789', address_line1: '9 Elm', city: 'Salem', state: 'MA', postal_code: '01970')
    { employee: employee, rate: rate, run: run, slip: slip, message: message, file: file, log: log, payee: payee }
  end

  CHECKS = {
    employee: [People::Employee, %w[address date_of_birth]], rate: [People::PayRate, %w[hourly_rate_cents]],
    run: [People::PayRun, %w[notes]], slip: [People::Payslip, %w[hours gross_cents deductions_cents net_cents notes]],
    message: [TeamChat::Message, %w[body]], file: [TeamChat::Attachment, %w[data]], log: [FeedbackAttachment, %w[text_body]],
    payee: [Finance::TaxPayee, %w[legal_name address_line1 city postal_code tin_last4]]
  }.freeze

  def assert_encrypted_on_disk(rows, expected: true)
    CHECKS.each do |key, (model, columns)|
      columns.each do |column|
        assert_equal expected, ciphertext?(model, rows[key].id, column), "#{model}##{column} ciphertext? should be #{expected}"
      end
    end
  end

  def assert_reads_plaintext(rows)
    employee = People::Employee.find(rows[:employee].id)
    assert_equal [Date.new(1990, 4, 5), rows[:employee].address], [employee.date_of_birth, employee.address]
    assert_equal 2_150, People::PayRate.find(rows[:rate].id).hourly_rate_cents
    slip = People::Payslip.find(rows[:slip].id)
    assert_equal [BigDecimal('40.5'), 87_075, 13_061, 74_014], [slip.hours, slip.gross_cents, slip.deductions_cents, slip.net_cents]
    assert_equal 87_075, People::PayRun.find(rows[:run].id).total_gross_cents
    assert_equal rows[:message].body, TeamChat::Message.find(rows[:message].id).body
    assert_equal PNG, TeamChat::Attachment.find(rows[:file].id).data.b
    assert_equal rows[:log].text_body, FeedbackAttachment.find(rows[:log].id).text_body
    payee = Finance::TaxPayee.find(rows[:payee].id)
    assert_equal [rows[:payee].legal_name, '9 Elm', 'Salem', '01970', '6789'], [payee.legal_name, payee.address_line1, payee.city, payee.postal_code, payee.tin_last4]
  end

  test 'new writes are ciphertext on disk and read back as plaintext' do
    rows = build_rows('New')
    assert_encrypted_on_disk(rows)
    assert_reads_plaintext(rows)
    assert_not raw(TeamChat::Message, rows[:message].id, 'body').include?('secret plan')

    filing = Finance::TaxFormFiling.issue!(Finance::Form1099Totals::Row.new(payee: rows[:payee], paid_cents: 70_000), year: 2026, kind: 'original')
    assert ciphertext?(Finance::TaxFormFiling, filing.id, 'legal_name')
    assert_equal 'Pat New', Finance::TaxFormFiling.find(filing.id).legal_name
  end

  test 'payroll totals are added up in Ruby, not by SQL over ciphertext' do
    rows = build_rows('Sum')
    other = People::Employee.create!(first_name: 'Bo', last_name: 'Sum', employee_number: 'E-Sum2')
    rows[:run].payslips.create!(employee: other, hours: 10, gross_cents: 1_000, deductions_cents: 150, net_cents: 850)
    assert_equal [88_075, 74_864], [rows[:run].total_gross_cents, rows[:run].total_net_cents]
    rows[:run].update!(total_gross_cents: rows[:run].total_gross_cents, total_net_cents: rows[:run].total_net_cents)
    assert ciphertext?(People::PayRun, rows[:run].id, 'total_gross_cents')
    assert_equal [88_075], People::PayRun.where(id: rows[:run].id).pluck(:total_gross_cents)
  end

  test 'the backfill dry run writes nothing; CONFIRM encrypts legacy rows once, within the named tenant' do
    legacy = ActiveRecord::Encryption.without_encryption { build_rows('Old') }
    assert_encrypted_on_disk(legacy, expected: false)
    assert_reads_plaintext(legacy) # support_unencrypted_data keeps old rows readable

    other_tenant = Tenant.create!(name: 'Other shop', subdomain: 'other-enc-shop')
    Current.tenant = other_tenant
    elsewhere = ActiveRecord::Encryption.without_encryption { build_rows('Far') }
    Current.tenant = @tenant

    before = raw(TeamChat::Message, legacy[:message].id, 'body')
    dry = SensitiveFieldEncryption.call(write: false, tenant_id: @tenant.id)
    assert_equal before, raw(TeamChat::Message, legacy[:message].id, 'body')
    assert_encrypted_on_disk(legacy, expected: false)
    assert_equal 0, dry.sum(&:rewritten)
    assert_equal 1, dry.find { |result| result.model == 'TeamChat::Message' }.plaintext

    written = SensitiveFieldEncryption.call(write: true, tenant_id: @tenant.id)
    assert_operator written.sum(&:rewritten), :>=, CHECKS.size
    assert_encrypted_on_disk(legacy)
    assert_reads_plaintext(legacy)
    assert_equal 0, SensitiveFieldEncryption.call(write: true, tenant_id: @tenant.id).sum(&:plaintext), 'a second run has nothing to do'

    # The other tenant was not touched, and its rows are still invisible from this tenant.
    assert_not ciphertext?(TeamChat::Message, elsewhere[:message].id, 'body')
    assert_nil TeamChat::Message.find_by(id: elsewhere[:message].id)
    assert_nil People::Employee.find_by(id: elsewhere[:employee].id)
    assert_equal 1, SensitiveFieldEncryption.call(write: false).find { |result| result.model == 'TeamChat::Message' }.plaintext
  end

  test 'the rake task is a dry run unless CONFIRM=1' do
    legacy = ActiveRecord::Encryption.without_encryption { build_rows('Rake') }
    Rails.application.load_tasks unless Rake::Task.task_defined?('ops:encrypt_sensitive_fields')
    task = Rake::Task['ops:encrypt_sensitive_fields']
    run = lambda do |env|
      env.each { |key, value| ENV[key] = value }
      task.reenable
      capture_io { task.invoke }.first
    ensure
      env.each_key { |key| ENV.delete(key) }
    end

    output = run.call('TENANT_ID' => @tenant.id)
    assert_match(/Dry run/, output)
    assert_not ciphertext?(TeamChat::Message, legacy[:message].id, 'body')

    output = run.call('TENANT_ID' => @tenant.id, 'CONFIRM' => '1')
    assert_match(/Encrypting/, output)
    assert ciphertext?(TeamChat::Message, legacy[:message].id, 'body')
    assert ciphertext?(People::Payslip, legacy[:slip].id, 'gross_cents')
  end
end
