# frozen_string_literal: true

require 'test_helper'
require 'rake'

# The backfill and the status check cover every model that declares `encrypts`, found by discovery rather
# than a hand-kept list, so a column encrypted later is backfilled and counted without touching the task.
class SensitiveFieldEncryptionCoverageTest < ActiveSupport::TestCase
  # Every model that declared `encrypts` when discovery replaced the hand-kept list of nine.
  KNOWN = %w[
    AuthorizeNetPortalExport AuthorizeNetPortalObservation AuthorizeNetSaleLink AuthorizeNetTransaction BankStatementLine
    BookApproval CtraxDay CtraxLaborObservation CtraxLaborShift DailyReconciliationReview FeedbackAttachment ImportBatch
    ImportDriveConnection ImportLine ImportSourceDocument ImportTransaction IrisReport MoneyReconciliation OwnerChecklist
    OwnerChecklistEvent PeriodLock PosCheckout PosConnection PosDisplaySession PosSetting PurchaseReceipt PurchaseReceiptEvent
    ReconciliationDocument ReconciliationFollowUp ReconciliationFollowUpEvent RetentionDriveConnection RetentionDriveItem
    Setting Shop SquareTimecard StockRequestEvent SupportAccessGrant SwipesimpleExport SwipesimpleReportPull
    SwipesimpleReportRow TeamChat::Attachment TeamChat::Message TrainingAttachment Upload WarehousePaymentAttempt
    WarehouseStockHold WorkspaceDeployment WorkspaceSignupEvent ZelleEntry ZelleExport
    Finance::TaxFormFiling Finance::TaxPayee Marketing::CmsEvent Marketing::DocumentRevision Marketing::Influencer
    Marketing::Interaction Marketing::ProductGift Marketing::ShopifyDiscount
    People::Employee People::PayRate People::PayRun People::Payslip
  ].freeze

  PROBE_TABLE = 'encryption_probe_records'
  BLOB = "\x89PNG\r\n\x1a\n\x00\xFFbytes".b

  # A model added after the task was written: discovery must find it with no change to the service.
  class ProbeRecord < ApplicationRecord
    self.table_name = PROBE_TABLE
    attribute :amount_cents, :integer
    encrypts :note, :amount_cents
    encrypts :lookup, deterministic: true
    encrypts :blob
    attr_readonly :note, :blob
  end

  # A model whose table does not exist (an engine not migrated yet, a table dropped ahead of its class).
  class MissingTableRecord < ApplicationRecord
    self.table_name = 'encryption_probe_missing'
    encrypts :secret
  end

  setup do
    @tenant = Tenant.create!(name: 'Enc coverage', subdomain: 'enc-coverage')
    @other = Tenant.create!(name: 'Enc other', subdomain: 'enc-coverage-other')
    Current.tenant = @tenant
    @user = users(:regular_user)
    ActiveRecord::Base.connection.create_table(PROBE_TABLE, force: true) do |t|
      t.string :tenant_id
      t.text :note
      t.text :amount_cents
      t.string :lookup
      t.binary :blob
      t.datetime :updated_at
    end
    ProbeRecord.reset_column_information
  end

  teardown do
    Current.reset
    ActiveRecord::Base.connection.drop_table(PROBE_TABLE, if_exists: true)
    ActiveRecord::Base.connection.schema_cache.clear_data_source_cache!(PROBE_TABLE)
    ProbeRecord.reset_column_information
  end

  def raw(model, id, column)
    model.connection.select_value("SELECT CAST(#{column} AS TEXT) FROM #{model.table_name} WHERE id = #{id.to_i}")
  end

  def ciphertext?(model, id, column) = raw(model, id, column).to_s.start_with?('{"p":')

  def insert_probe(tenant_id, note:, amount:, lookup:, blob:)
    ActiveRecord::Encryption.without_encryption do
      ProbeRecord.create!(tenant_id: tenant_id, note: note, amount_cents: amount, lookup: lookup, blob: blob,
        updated_at: Time.utc(2026, 1, 2, 3, 4, 5)).id
    end
  end

  # Legacy rows of several real column kinds in the given tenant, written before encryption.
  def legacy_rows(tag)
    ActiveRecord::Encryption.without_encryption do
      employee = People::Employee.create!(first_name: 'Ana', last_name: tag, employee_number: "E-#{tag}", address: "1 #{tag} Way")
      rate = People::PayRate.create!(employee: employee, pay_type: 'hourly', hourly_rate_cents: 2_150, effective_on: '2026-01-01')
      room = TeamChat::Room.create!(name: "enc-#{tag.downcase}", slug: "enc-#{tag.downcase}", kind: 'channel', created_by: @user)
      message = room.messages.create!(user: @user, body: "legacy #{tag}")
      feedback = AgentFeedback.create!(kind: 'bug', summary: 'Broken', source: 'app')
      shot = FeedbackAttachment.create!(agent_feedback: feedback, kind: 'screenshot', content_type: 'image/png', binary_body: BLOB)
      payee = Finance::TaxPayee.create!(payee_key: "p:#{tag.downcase}", legal_name: "Pat #{tag}", tax_classification: 'individual',
        form_type: 'nec', city: 'Salem', state: 'MA')
      { employee: employee, rate: rate, message: message, shot: shot, payee: payee }
    end
  end

  def plaintext_for(results, model) = results.find { |result| result.model == model.name }.plaintext

  test 'discovery covers every known encrypting model and picks up a new one automatically' do
    names = SensitiveFieldEncryption.models.map(&:name)
    assert_empty KNOWN - names, 'every model that declares encrypts is discovered'
    assert_operator names.size, :>=, KNOWN.size
    assert_includes names, ProbeRecord.name
    assert_not_includes names, 'ApplicationRecord'

    targets = SensitiveFieldEncryption.targets.index_by { |target| target.model.name }
    assert_equal %w[note amount_cents lookup blob].sort, targets[ProbeRecord.name].attributes.sort
    assert_match(/table encryption_probe_missing is missing/, targets[MissingTableRecord.name].skipped)
    result = SensitiveFieldEncryption.call(models: [MissingTableRecord.name]).first
    assert_equal 0, result.plaintext
    assert_match(/skipped/, result.line(false))
  end

  test 'dry run writes nothing; CONFIRM encrypts string, text, integer, blob, deterministic and read-only columns once' do
    rows = legacy_rows('Mix')
    probe = insert_probe(@tenant.id, note: 'probe note', amount: 4_200, lookup: 'Find Me', blob: BLOB)
    before = ProbeRecord.connection.select_rows("SELECT * FROM #{PROBE_TABLE}")

    dry = SensitiveFieldEncryption.call(write: false, tenant_id: @tenant.id)
    assert_equal before, ProbeRecord.connection.select_rows("SELECT * FROM #{PROBE_TABLE}"), 'the dry run wrote nothing'
    assert_not ciphertext?(TeamChat::Message, rows[:message].id, 'body')
    assert_equal 0, dry.sum(&:rewritten)
    [People::Employee, People::PayRate, TeamChat::Message, FeedbackAttachment, Finance::TaxPayee, ProbeRecord].each do |model|
      assert_equal 1, plaintext_for(dry, model), "#{model} legacy row counted"
    end

    written = SensitiveFieldEncryption.call(write: true, tenant_id: @tenant.id)
    assert_equal dry.sum(&:plaintext), written.sum(&:rewritten)
    { People::Employee => [rows[:employee].id, 'address'], People::PayRate => [rows[:rate].id, 'hourly_rate_cents'],
      TeamChat::Message => [rows[:message].id, 'body'], FeedbackAttachment => [rows[:shot].id, 'binary_body'],
      Finance::TaxPayee => [rows[:payee].id, 'city'] }.each do |model, (id, column)|
      assert ciphertext?(model, id, column), "#{model}##{column} is ciphertext"
    end
    %w[note amount_cents lookup blob].each { |column| assert ciphertext?(ProbeRecord, probe, column), "probe #{column}" }

    assert_equal 2_150, People::PayRate.find(rows[:rate].id).hourly_rate_cents
    assert_equal BLOB, FeedbackAttachment.find(rows[:shot].id).binary_body.b
    assert_equal 'Salem', Finance::TaxPayee.find(rows[:payee].id).city
    record = ProbeRecord.find(probe)
    assert_equal ['probe note', 4_200, 'Find Me', BLOB], [record.note, record.amount_cents, record.lookup, record.blob.b]
    assert_equal [probe], ProbeRecord.where(lookup: 'Find Me').pluck(:id), 'deterministic values stay searchable'
    assert_equal Time.utc(2026, 1, 2, 3, 4, 5), record.updated_at, 'updated_at is untouched'

    again = SensitiveFieldEncryption.call(write: true, tenant_id: @tenant.id)
    assert_equal [0, 0], [again.sum(&:plaintext), again.sum(&:rewritten)], 'a second run has nothing to do'
  end

  test 'TENANT_ID limits the backfill to that tenant' do
    mine = insert_probe(@tenant.id, note: 'mine', amount: 1, lookup: 'a', blob: BLOB)
    theirs = insert_probe(@other.id, note: 'theirs', amount: 2, lookup: 'b', blob: BLOB)
    Current.tenant = @other
    elsewhere = legacy_rows('Far')
    Current.tenant = @tenant

    SensitiveFieldEncryption.call(write: true, tenant_id: @tenant.id)
    assert ciphertext?(ProbeRecord, mine, 'note')
    assert_not ciphertext?(ProbeRecord, theirs, 'note')
    assert_not ciphertext?(TeamChat::Message, elsewhere[:message].id, 'body')
    assert_equal 1, plaintext_for(SensitiveFieldEncryption.status(tenant_id: @other.id), TeamChat::Message)

    # A model without a tenant column is left for the all-tenant run rather than rewritten across tenants.
    shop = SensitiveFieldEncryption.call(write: false, tenant_id: @tenant.id, models: %w[Shop]).first
    assert_match(/no tenant_id column/, shop.skipped) unless Shop.column_names.include?('tenant_id')
  end

  test 'status counts plaintext per model, records the total, and exits 1 until it is zero' do
    legacy_rows('Stat')
    insert_probe(@tenant.id, note: 'n', amount: 3, lookup: 'c', blob: BLOB)
    status = SensitiveFieldEncryption.status(tenant_id: @tenant.id)
    total = status.sum(&:plaintext)
    assert_operator total, :>=, 6
    assert_equal 1, plaintext_for(status, ProbeRecord)
    assert_match(/1 plaintext of 1 rows/, status.find { |result| result.model == ProbeRecord.name }.status_line)

    Dir.mktmpdir do |dir|
      file = File.join(dir, 'encryption_status.json')
      ENV['RUPERT_ENCRYPTION_STATUS_FILE'] = file
      Rails.application.load_tasks unless Rake::Task.task_defined?('ops:encryption_status')
      task = Rake::Task['ops:encryption_status']
      run = lambda do |env = {}|
        env.each { |key, value| ENV[key] = value }
        task.reenable
        code = 0
        out = capture_io do
          task.invoke
        rescue SystemExit => e
          code = e.status
        end.first
        [out, code]
      ensure
        env.each_key { |key| ENV.delete(key) }
      end

      out, code = run.call('TENANT_ID' => @tenant.id)
      assert_equal 1, code
      assert_match(/Total: #{total} rows with plaintext/, out)
      assert_match(/Not ready/, out)
      assert_not File.exist?(file), 'a single-tenant status is not recorded for System health'

      SensitiveFieldEncryption.call(write: true, tenant_id: @tenant.id)
      out, code = run.call('TENANT_ID' => @tenant.id)
      assert_equal [0, true], [code, out.include?('Total: 0 rows with plaintext')]

      _out, _code = run.call
      recorded = SensitiveFieldEncryption.last_status
      assert_operator recorded[:models], :>=, KNOWN.size
      assert_kind_of Integer, recorded[:plaintext]
      assert_not_nil recorded[:at]
    ensure
      ENV.delete('RUPERT_ENCRYPTION_STATUS_FILE')
    end
  end
end
