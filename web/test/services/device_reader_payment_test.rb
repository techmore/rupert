# frozen_string_literal: true

require 'test_helper'
require_relative '../support/device_reader_fixture'

# Phone card reader payments against the fake provider: the phone's report is a
# hint, the provider lookup decides, and nothing is ever charged twice.
class DeviceReaderPaymentTest < ActiveSupport::TestCase
  include DeviceReaderFixture
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  Payment = Pos::DeviceReaderPayment

  setup do
    @lock_dir = Dir.mktmpdir('pos-reconciliation-lock')
    PosPaymentReconciliationJob.any_instance.stubs(:lock_path).returns(Pathname(@lock_dir).join('reconciliation.lock'))
    Current.tenant = tenants(:default_tenant)
    prepare_device_reader_fixture
  end
  teardown { Current.reset }

  def open_and_start
    opened = Payment.open!(@checkout)
    Payment.start!(opened, device_id: DEVICE)
    opened
  end

  def report(body, device_id: DEVICE) = Payment.report!(attempt, device_id: device_id, report: body)

  test 'opening saves one durable attempt with a server-set amount and reference before any reader runs' do
    opened = Payment.open!(@checkout)
    assert_equal %w[device_reader submitting], [opened.provider, opened.status]
    assert_equal 'processing', @checkout.reload.status
    assert_match(/\ARR[0-9a-f]{24}\z/, opened.invoice)
    token = Payment.token_for(opened)
    assert_equal opened, Payment.find_by_token(token)
    refute_includes opened.attributes.values.map(&:to_s), token, 'only the digest of the token is stored'
    params = Payment.start!(opened, device_id: DEVICE)
    assert_equal({ reference: opened.invoice, amount_cents: 1166, tip_cents: 101, currency: 'USD' }, params.slice(:reference, :amount_cents, :tip_cents, :currency))
    assert_equal({}, params[:reader])
    refute_includes opened.reload.attributes.to_json, DEVICE, 'only a digest of the install identifier is stored'
    assert_includes audit_actions, 'pos_device_reader_attempt_opened'
    assert_equal 0, provider_lookups
  end

  test 'a double tap opens one attempt' do
    first = Payment.open!(@checkout)
    second = Payment.open!(@checkout)
    assert_equal first, second
    assert_equal 1, @checkout.pos_payment_attempts.count
    assert_equal 1, audit_actions.count('pos_device_reader_attempt_opened')
    Payment.start!(first, device_id: DEVICE)
    Payment.start!(first, device_id: DEVICE)
    report(tap)
    assert_equal first, Payment.open!(@checkout), 'still the same attempt while it awaits confirmation'
    assert_equal 1, @checkout.pos_payment_attempts.count
  end

  test 'the database refuses a second unresolved phone attempt for one checkout' do
    Payment.open!(@checkout)
    assert_raises(ActiveRecord::RecordNotUnique) do
      @checkout.pos_payment_attempts.create!(provider: 'device_reader', invoice: 'RRsecond', nonce_digest: 'second', submitted_at: Time.current)
    end
  end

  test 'report then lookup marks the sale paid once' do
    open_and_start
    assert_equal :recorded, report(tap)
    assert_equal %w[unknown unknown], [attempt.status, @checkout.reload.status], 'reported, awaiting confirmation'
    assert_not @checkout.paid?
    Pos::CardPayment.reconcile!(attempt)
    assert @checkout.reload.paid?
    assert_equal 'paid', attempt.status
    assert_equal({ processor: 'Phone card reader', brand: 'Visa', last_four: '1111', auth_code: 'A1B2C3' }, @checkout.receipt[:card].slice(:processor, :brand, :last_four, :auth_code))
    assert @checkout.receipt[:sandbox]
    Pos::CardPayment.reconcile!(attempt)
    Payment.reconcile!(attempt)
    assert_equal 1, audit_actions.count('pos_sandbox_checkout_completed'), 'finalized once'
    assert_equal 1, provider_lookups, 'a paid attempt is not looked up again'
    assert_includes audit_actions, 'pos_device_reader_result_reported'
  end

  test 'a report without a lookup never marks the sale paid' do
    open_and_start
    report(tap)
    assert_equal 0, provider_lookups
    assert_not @checkout.reload.paid?
    assert_nil @checkout.paid_at
    assert_nil @checkout.receipt[:card]
    assert_nil attempt.card_last_four, 'reported card details are not copied to the verified columns'
    assert_equal 'approved', attempt.device_report['status']
    # Even an approval the provider never saw stays unpaid.
    Pos::DeviceReader::FakeGateway.reset!
    assert_match(/not reported this payment yet/, assert_raises(Pos::Error) { Payment.reconcile!(attempt) }.message)
    assert_not @checkout.reload.paid?
  end

  test 'a lookup without a report still resolves the sale' do
    open_and_start
    tap
    Payment.reconcile!(attempt)
    assert @checkout.reload.paid?
    assert_nil attempt.device_reported_at
  end

  test 'a lost result is resolved by the sweep' do
    open_and_start
    tap
    PosPaymentReconciliationJob.perform_now
    assert_equal 'submitting', attempt.status, 'too fresh for the sweep'
    travel 90.seconds do
      PosPaymentReconciliationJob.perform_now
    end
    assert @checkout.reload.paid?
    assert_equal 1, provider_lookups
  end

  test 'a reader that never answers is closed by the sweep only after the wait, and never charged again' do
    open_and_start
    assert_nil tap(:timeout)
    travel 2.minutes do
      PosPaymentReconciliationJob.perform_now
      assert_equal %w[submitting processing], [attempt.status, @checkout.reload.status], 'the reader may still be waiting'
      assert_equal attempt, Payment.open!(@checkout), 'no second attempt while one is unresolved'
    end
    travel 6.minutes do
      PosPaymentReconciliationJob.perform_now
    end
    assert_equal %w[declined declined], [attempt.status, @checkout.reload.status]
    assert_equal Payment::NO_RECORD, attempt.decline_reason
    travel 7.minutes do
      fresh = Payment.open!(@checkout)
      assert_not_equal attempt.invoice.then { fresh.invoice }, @checkout.pos_payment_attempts.order(:id).first.invoice, 'a new attempt has a new reference'
      assert_equal 2, @checkout.pos_payment_attempts.count
    end
  end

  test 'a decline or customer cancel resolves at once and allows a fresh attempt' do
    open_and_start
    report(tap(:declined))
    Payment.reconcile!(attempt)
    assert_equal %w[declined declined], [attempt.status, @checkout.reload.status]
    assert_equal Payment::DECLINED, attempt.decline_reason
    first = attempt
    open_and_start
    assert_not_equal first, attempt
    report(tap(:cancelled))
    Payment.reconcile!(attempt)
    assert_equal Payment::CANCELED, attempt.decline_reason
    open_and_start
    report(tap)
    Payment.reconcile!(attempt)
    assert @checkout.reload.paid?
    assert_equal 3, @checkout.pos_payment_attempts.pluck(:invoice).uniq.size
  end

  test 'cancelling an unreported attempt is confirmed by lookup before it is closed' do
    opened = open_and_start
    Payment.cancel!(opened, device_id: DEVICE)
    assert_equal %w[unknown unknown], [attempt.status, @checkout.reload.status]
    assert_includes audit_actions, 'pos_device_reader_cancel_requested'
    Payment.reconcile!(attempt)
    assert_equal %w[declined declined], [attempt.status, @checkout.reload.status]
    assert_equal Payment::CANCELED, attempt.decline_reason
  end

  test 'a cancel that raced an approval ends paid, not lost' do
    opened = open_and_start
    tap
    Payment.cancel!(opened, device_id: DEVICE)
    Payment.reconcile!(attempt)
    assert @checkout.reload.paid?
  end

  test 'an attempt that was reported cannot be cancelled, and a page cannot cancel a started one' do
    opened = open_and_start
    assert_raises(Payment::WrongDevice) { Payment.cancel!(opened) }
    assert_raises(Payment::WrongDevice) { Payment.cancel!(opened, device_id: OTHER_DEVICE) }
    report(tap)
    assert_match(/already reported/, assert_raises(Pos::Error) { Payment.cancel!(opened, device_id: DEVICE) }.message)
    assert_equal 'approved', attempt.device_report['status']
  end

  test 'an attempt no phone started can be cancelled from the page' do
    opened = Payment.open!(@checkout)
    Payment.cancel!(opened)
    Payment.reconcile!(attempt)
    assert_equal 'declined', @checkout.reload.status
  end

  test 'an approval for a different amount is refused and held for review' do
    open_and_start
    wrong = tap(:wrong_amount)
    assert_equal 1201, wrong['amount_cents']
    assert_raises(Payment::AmountMismatch) { report(wrong) }
    assert_nil attempt.device_reported_at, 'the mismatched report was not recorded'
    assert_match(/different amount/, assert_raises(Pos::Error) { Payment.reconcile!(attempt) }.message)
    assert_equal %w[unknown unknown], [attempt.status, @checkout.reload.status]
    assert_equal Pos::DeclineReason::REVIEW, attempt.decline_reason
    assert_not @checkout.paid?
    assert_equal attempt, Payment.open!(@checkout), 'held for review: no new charge can start'
    travel 3.minutes do
      PosPaymentReconciliationJob.perform_now
    end
    assert_includes audit_actions, 'pos_payment_needs_review'
    assert_not @checkout.reload.paid?
  end

  test 'a phone that lies about the amount cannot make a wrong-amount approval paid' do
    open_and_start
    tap(:wrong_amount)
    report({ 'status' => 'approved', 'amount_cents' => 1166 })
    assert_raises(Pos::Error) { Payment.reconcile!(attempt) }
    assert_not @checkout.reload.paid?
    assert_equal Pos::DeclineReason::REVIEW, attempt.decline_reason
  end

  test 'an approval under another reference is never accepted' do
    open_and_start
    Pos::DeviceReader::FakeGateway.present_card(reference: 'RRsomeoneelse', amount_cents: 1166, tip_cents: 101)
    row = Pos::DeviceReader::FakeGateway.row('RRsomeoneelse')
    Pos::DeviceReader::FakeGateway.any_instance.stubs(:lookup).returns(
      Pos::DeviceReader::Result.new(outcome: 'approved', reference_id: 'RRsomeoneelse', kind: 'sale', currency: 'USD', total_cents: 1166, tip_cents: 101,
        fee_cents: 0, processor_reference: row[:processor_reference], auth_code: 'A1B2C3', card_brand: 'Visa', card_last_four: '1111',
        entry_method: 'contactless', voided: false, settled: false)
    )
    assert_raises(Pos::Error) { Payment.reconcile!(attempt) }
    assert_not @checkout.reload.paid?
    assert_equal Pos::DeclineReason::REVIEW, attempt.decline_reason
  end

  test 'a partial approval is voided at once and nothing is charged' do
    open_and_start
    tap(:partial)
    Payment.reconcile!(attempt)
    assert_equal %w[declined declined], [attempt.status, @checkout.reload.status]
    assert_equal Payment::PARTIAL_REVERSED, attempt.decline_reason
    assert Pos::DeviceReader::FakeGateway.row(attempt.invoice)[:voided]
  end

  test 'a partial approval that cannot be voided is held for review' do
    open_and_start
    tap(:partial)
    Pos::DeviceReader::FakeGateway.settle!(attempt.invoice)
    assert_match(/could not be reversed/, assert_raises(Pos::Error) { Payment.reconcile!(attempt) }.message)
    assert_equal %w[unknown unknown], [attempt.status, @checkout.reload.status]
    assert_equal Pos::DeclineReason::REVIEW, attempt.decline_reason
  end

  test 'a sale voided at the provider is not a sale' do
    open_and_start
    tap
    Pos::DeviceReader.gateway(@setting).void(reference: attempt.invoice, amount_cents: 1166)
    Payment.reconcile!(attempt)
    assert_equal 'declined', @checkout.reload.status
    assert_equal Payment::VOIDED, attempt.decline_reason
  end

  test 'a provider that does not answer leaves the sale unresolved, not declined and not retried' do
    open_and_start
    report(tap)
    Pos::DeviceReader::FakeGateway.fail_next(:lookup)
    assert_raises(Pos::Error) { Payment.reconcile!(attempt) }
    assert_equal %w[unknown unknown], [attempt.status, @checkout.reload.status]
    Payment.reconcile!(attempt)
    assert @checkout.reload.paid?
  end

  test 'a duplicate report is harmless' do
    open_and_start
    approved = tap
    assert_equal :recorded, report(approved)
    first = attempt.device_reported_at
    assert_equal :duplicate, report(approved)
    assert_equal :duplicate, report({ 'status' => 'declined' }), 'a later contradicting report changes nothing'
    assert_equal 'approved', attempt.device_report['status']
    assert_equal first, attempt.device_reported_at
    assert_equal 1, audit_actions.count('pos_device_reader_result_reported')
    Payment.reconcile!(attempt)
    assert_equal :duplicate, report(approved)
    assert @checkout.reload.paid?
    assert_equal 1, audit_actions.count('pos_sandbox_checkout_completed')
  end

  test 'a late approval for an abandoned attempt pays the still-open checkout instead of losing the sale' do
    open_and_start
    travel 6.minutes do
      Payment.reconcile!(attempt)
      assert_equal 'declined', @checkout.reload.status
      assert_equal :late, report(tap)
      assert_equal 'declined', attempt.status, 'the late report by itself changes no status'
      assert_not @checkout.reload.paid?
      before = provider_lookups
      PosDeviceReaderConfirmJob.perform_now(attempt.id, attempt.tenant_id)
      PosDeviceReaderConfirmJob.perform_now(attempt.id, attempt.tenant_id)
      assert_equal before + 1, provider_lookups, 'looked up once'
    end
    assert @checkout.reload.paid?
    assert_equal 'paid', attempt.status
    assert_nil attempt.decline_reason
  end

  test 'a late approval after the checkout was paid another way is held for review, not paid twice' do
    abandoned = open_and_start
    travel 6.minutes do
      Payment.reconcile!(abandoned)
      open_and_start
      report(tap)
      Payment.reconcile!(attempt)
      assert @checkout.reload.paid?
      paid_at = @checkout.paid_at
      assert_equal :late, Payment.report!(abandoned, device_id: DEVICE, report: tap(:approved, attempt: abandoned))
      assert_match(/already closed/, assert_raises(Pos::Error) { Payment.reconcile!(abandoned) }.message)
      assert_equal 'declined', abandoned.reload.status
      assert_equal Pos::DeclineReason::REVIEW, abandoned.decline_reason
      assert abandoned.transaction_id.present?
      assert_equal paid_at, @checkout.reload.paid_at
      assert_equal 1, @checkout.pos_payment_attempts.where(status: 'paid').count
      assert_equal 1, audit_actions.count('pos_sandbox_checkout_completed')
    end
  end

  test 'a late decline changes nothing' do
    open_and_start
    travel 6.minutes do
      Payment.reconcile!(attempt)
      assert_equal :late, report(tap(:declined))
      PosDeviceReaderConfirmJob.perform_now(attempt.id, attempt.tenant_id)
      assert_equal 'declined', @checkout.reload.status
      assert_equal Payment::NO_RECORD, attempt.decline_reason
    end
  end

  test 'only the device that started the reader may report, and only after it started' do
    opened = Payment.open!(@checkout)
    assert_raises(Payment::WrongDevice) { report({ 'status' => 'approved', 'amount_cents' => 1166 }) }
    Payment.start!(opened, device_id: DEVICE)
    assert_raises(Payment::WrongDevice) { Payment.start!(opened, device_id: OTHER_DEVICE) }
    assert_raises(Payment::WrongDevice) { report({ 'status' => 'approved', 'amount_cents' => 1166 }, device_id: OTHER_DEVICE) }
    assert_raises(Payment::WrongDevice) { report({ 'status' => 'approved', 'amount_cents' => 1 }, device_id: OTHER_DEVICE) }
    assert_raises(Pos::Error) { report({ 'status' => 'approved', 'amount_cents' => 1166 }, device_id: 'short') }
    assert_nil attempt.device_reported_at
    assert_equal 'submitting', attempt.status
  end

  test 'the reader cannot be started for an expired or resolved attempt' do
    opened = Payment.open!(@checkout)
    travel 4.minutes do
      assert_match(/expired/, assert_raises(Pos::Error) { Payment.start!(opened, device_id: DEVICE) }.message)
    end
    Payment.start!(opened, device_id: DEVICE)
    report(tap)
    assert_match(/no longer waiting/, assert_raises(Pos::Error) { Payment.start!(opened, device_id: DEVICE) }.message)
  end

  test 'a token finds its attempt only in its own workspace' do
    opened = Payment.open!(@checkout)
    token = Payment.token_for(opened)
    assert_equal opened, Payment.find_by_token(token)
    assert_nil Payment.find_by_token(token.tr('0-9a-f', '1-9a-f0'))
    assert_nil Payment.find_by_token(nil)
    assert_nil Payment.find_by_token('4111111111111111')
    create_workspace('Other reader shop')
    assert_nil Payment.find_by_token(token)
  end

  test 'a report keeps only the short list of fields and refuses everything else' do
    full = { 'status' => 'approved', 'provider_reference' => 'FAKE-123', 'amount_cents' => 1166, 'card_brand' => 'Visa', 'last_four' => '1111',
             'entry_method' => 'contactless', 'auth_code' => 'A1B2C3' }
    assert_equal full, Payment.clean_report(full)
    assert_equal({ 'status' => 'cancelled' }, Payment.clean_report(status: 'cancelled', auth_code: nil))
    [full.merge('first_six' => '411111'), full.merge('cardholder' => 'PAT CARDHOLDER'), full.merge('expiry' => '1229'),
     full.merge('status' => 'paid'), full.merge('last_four' => '41111'), full.merge('card_brand' => 'Visa 4111'),
     full.merge('amount_cents' => '1166'), full.merge('amount_cents' => 11.66), full.except('amount_cents'),
     full.merge('provider_reference' => 'has spaces'), full.merge('entry_method' => ['contactless']), 'approved', nil].each do |bad|
      assert_raises(Pos::Error, bad.inspect) { Payment.clean_report(bad) }
    end
    open_and_start
    report(full.merge('provider_reference' => tap['provider_reference']))
    assert_equal Payment::REPORT_KEYS.sort, attempt.device_report.keys.sort
  end

  test 'two workers cannot both confirm the same attempt' do
    open_and_start
    report(tap)
    assert PosPaymentAttempt.claim_reconciliation(attempt.id), 'the first worker claims it'
    assert_not PosPaymentAttempt.claim_reconciliation(attempt.id), 'the second worker is turned away'
    PosDeviceReaderConfirmJob.perform_now(attempt.id, attempt.tenant_id)
    travel 90.seconds do
      PosPaymentReconciliationJob.perform_now
    end
    assert_equal 0, provider_lookups, 'a claimed attempt is looked up by neither the confirm job nor the sweep'
    assert_not @checkout.reload.paid?
    travel 3.minutes do
      PosPaymentReconciliationJob.perform_now
      PosDeviceReaderConfirmJob.perform_now(attempt.id, attempt.tenant_id)
    end
    assert @checkout.reload.paid?
    assert_equal 1, provider_lookups
    assert_equal 1, audit_actions.count('pos_sandbox_checkout_completed')
  end

  test 'two confirmations that both see the approval finalize the sale once' do
    open_and_start
    report(tap)
    stale = PosPaymentAttempt.find(attempt.id)
    Payment.reconcile!(attempt)
    Payment.send(:approve!, @checkout.reload, stale, Pos::DeviceReader.gateway(@setting).lookup(stale.invoice))
    assert_equal 1, audit_actions.count('pos_sandbox_checkout_completed')
    assert_equal 1, @checkout.pos_payment_attempts.where(status: 'paid').count
  end

  test 'the confirm job resolves a report at once, logs a review, and ignores other providers' do
    open_and_start
    report(tap)
    PosDeviceReaderConfirmJob.perform_now(attempt.id, attempt.tenant_id)
    assert @checkout.reload.paid?
    other = device_reader_checkout(display: PosDisplaySession.create!(user: @user, location: @location))
    @checkout = other
    open_and_start
    tap(:wrong_amount)
    PosDeviceReaderConfirmJob.perform_now(attempt.id, attempt.tenant_id)
    assert_equal 'unknown', other.reload.status
    assert_equal 'pos_payment_needs_review', ActivityLog.order(:id).last.action
    plain = PosPaymentAttempt.create!(pos_checkout: other, invoice: 'plain', nonce_digest: 'plain', status: 'declined', submitted_at: Time.current)
    before = provider_lookups
    PosDeviceReaderConfirmJob.perform_now(plain.id, plain.tenant_id)
    PosDeviceReaderConfirmJob.perform_now(attempt.id, create_workspace('Elsewhere', current: false).id)
    PosDeviceReaderConfirmJob.perform_now(attempt.id, 'no-such-workspace')
    assert_equal before, provider_lookups
  end

  test 'a real sale creates one order, register revenue and stock hand-off once the provider confirms' do
    @setting.update!(environment: 'production', production_approved_at: Time.current, production_approved_by: @user,
      production_approval_note: 'Fixture approval recorded for the test')
    @setting.update!(verified_at: Time.current)
    @setting.update!(card_enabled: true)
    @checkout.update!(environment: 'production', gateway_fingerprint: @setting.reload.payment_fingerprint)
    open_and_start
    report(tap)
    assert_empty Core::Order.where(source: 'rupert_pos')
    assert_enqueued_with(job: PosInventoryJob) { PosDeviceReaderConfirmJob.perform_now(attempt.id, attempt.tenant_id) }
    assert @checkout.reload.paid?
    order = Core::Order.find_by!(source: 'rupert_pos', source_order_id: @checkout.reference)
    assert_equal [1166], order.payments.pluck(:amount_cents)
    assert_equal 1166, @register.reload.card_sales_cents
    PosDeviceReaderConfirmJob.perform_now(attempt.id, attempt.tenant_id)
    Payment.reconcile!(attempt)
    assert_equal 1, Core::Order.where(source: 'rupert_pos').count
    assert_equal 1166, @register.reload.card_sales_cents
    assert_includes audit_actions, 'pos_checkout_paid'
  end

  test 'a closed register or a changed setup refuses a new attempt' do
    @setting.update!(environment: 'production', production_approved_at: Time.current, production_approved_by: @user,
      production_approval_note: 'Fixture approval recorded for the test')
    @setting.update!(verified_at: Time.current)
    @setting.update!(card_enabled: true)
    @checkout.update!(environment: 'production', gateway_fingerprint: @setting.reload.payment_fingerprint)
    @register.update_columns(status: 'closed')
    assert_match(/register is closed/, assert_raises(Pos::Error) { Payment.open!(@checkout) }.message)
    @register.update_columns(status: 'open')
    @setting.update!(credentials_json: { merchant_id: 'FIXTURE-OTHER', reader_profile_id: 'FIXTURE-PROFILE' }.to_json, production_approved_at: Time.current,
      production_approved_by: @user, production_approval_note: 'Fixture approval recorded again')
    assert_raises(Pos::Error) { Payment.open!(@checkout) }
    assert_equal 0, @checkout.pos_payment_attempts.count
  end

  test 'a demo checkout, a cash checkout and another provider never reach the card reader' do
    @checkout.update!(demo: true)
    assert_raises(Pos::Error) { Payment.open!(@checkout) }
    @checkout.update!(demo: false, tender: 'cash')
    assert_raises(Pos::Error) { Payment.open!(@checkout) }
    @checkout.update!(tender: 'card')
    assert_match(/phone card reader/, assert_raises(Pos::Error) { Pos::CardPayment.call(@checkout, nonce: 'fixture-nonce') }.message)
    assert_equal 0, @checkout.pos_payment_attempts.count
  end

  test 'a workspace with an enforced approved list cannot charge on the reader, which has no list of its own yet' do
    assert Payments::ItemEligibility.check(processor: 'device_reader', items: @checkout.lines).allowed?
    ProcessorCatalog.create!(processor: 'dejavoo_spin', enforced: true, approval_reference: 'Fixture approval 2026-11-18')
    assert_match(/no approved product list yet/, assert_raises(Pos::Error) { Payment.open!(@checkout) }.message)
    assert_equal 0, @checkout.pos_payment_attempts.count
    assert_not_includes ProcessorCatalog.visible_processors, 'device_reader'
    assert_not_includes Payments::ItemEligibility.check(processor: 'dejavoo_spin', items: @checkout.lines).alternatives, 'device_reader'
    assert_equal ['not on the Dejavoo terminal approved list'], Payments::ItemEligibility.check(processor: 'dejavoo_spin', items: @checkout.lines).blocked.map { |row| row[:reason] },
      'other processors keep their own answer'
  end
end
