# frozen_string_literal: true

require 'test_helper'
require_relative '../support/pdf_text'

# Settings → Backups (#421): who may create a backup key, the one-time recovery kit, and proof that the private key
# is never kept by the server.
class BackupKeysTest < ActionDispatch::IntegrationTest
  include PdfText

  CODE = /[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}/
  IDENTITY = /AGE-SECRET-KEY-1[0-9A-Z]{58}/

  setup do
    @tenant = tenants(:default_tenant)
    @owner = users(:regular_user)
    @owner.update!(role: 'super_admin', password: 'password123')
    Current.tenant = @tenant
  end

  teardown { Current.reset }

  def sign_in(user = @owner)
    post login_path, params: { email: user.email, password: 'password123' }
  end

  def create_key(**params)
    post settings_backup_key_path, params: { acknowledge: '1' }.merge(params)
  end

  # Every stored value in the database, raw (as on disk) and decrypted through the models that encrypt.
  def everything_stored
    conn = ActiveRecord::Base.connection
    raw = conn.tables.flat_map { |table| conn.select_rows("SELECT * FROM #{conn.quote_table_name(table)}").flatten.map(&:to_s) }
    raw + Setting.all.map(&:value).map(&:to_s) + ActivityLog.all.map { |log| log.attributes.values.join(' ') }
  end

  test 'the owner creates a key, gets the kit once, and the private key is stored nowhere' do
    sign_in
    get settings_backups_path
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_select '#backup-key[data-backup-key-state=missing]'
    assert_select 'input[type=submit][value=?]', 'Create backup key'

    log = Rails.root.join('log/test.log')
    log_offset = log.exist? ? log.size : 0
    assert_difference('BackupEncryptionKey.count', 1) { create_key }
    assert_response :success
    assert_equal 'application/pdf', response.media_type
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_match(/attachment; filename="rupert-backup-recovery-kit-[0-9a-f]{16}\.pdf"/, response.headers['Content-Disposition'])
    pdf = pdf_text(response.body)
    identity = pdf[IDENTITY]
    assert identity, 'the kit carries the private key'
    key = BackupEncryptionKey.last
    assert_equal key.recipient, BackupEncryption::AgeKey.recipient_for(identity)
    assert_includes pdf, key.fingerprint
    assert_equal 'pending', key.state
    assert_nil BackupEncryptionKey.current, 'not used until the kit is confirmed'

    stored = everything_stored
    assert stored.none? { |value| value.include?(identity) || value.include?(identity.downcase) }, 'private key found in the database'
    assert stored.none? { |value| value.include?(identity[16, 30]) }, 'part of the private key found in the database'
    if log.exist?
      written = File.binread(log, nil, log_offset)
      assert_not_includes written, identity, 'private key found in the log'
      assert_not_includes written, identity[16, 30]
    end
    created = ActivityLog.find_by(action: 'backup_key_created')
    assert created
    assert_includes created.details, key.fingerprint
    assert_not_includes created.details.to_s, 'AGE-SECRET'

    # Activation with the check code printed on the kit.
    code = pdf[CODE]
    post activate_settings_backup_key_path, params: { check_code: 'ZZZZ-ZZZZ' }
    assert_redirected_to settings_backups_path
    assert_nil BackupEncryptionKey.current
    post activate_settings_backup_key_path, params: { check_code: code.downcase }
    assert_redirected_to settings_backups_path
    assert_equal key, BackupEncryptionKey.current
    assert ActivityLog.exists?(action: 'backup_key_activated')
    assert ActivityLog.exists?(action: 'backup_key_activation_failed')

    get settings_backups_path
    assert_select '[data-current-fingerprint]', text: key.fingerprint
    assert_not_includes response.body, identity, 'the kit is never shown again'
  end

  test 'rotating keeps the old key listed as retired' do
    sign_in
    create_key
    first = BackupEncryptionKey.last
    post activate_settings_backup_key_path, params: { check_code: pdf_text(response.body)[CODE] || flunk('no code') }
    create_key
    second = BackupEncryptionKey.last
    assert_equal first, BackupEncryptionKey.current, 'the old key stays in use until the new kit is confirmed'
    post activate_settings_backup_key_path, params: { check_code: pdf_text(response.body)[CODE] }
    assert_equal second, BackupEncryptionKey.current
    assert_equal 'retired', first.reload.state
    get settings_backups_path
    assert_select 'tr[data-key-state=retired] td', text: first.fingerprint
  end

  test 'creating a key needs the acknowledgement and a recent sign-in' do
    sign_in
    assert_no_difference('BackupEncryptionKey.count') { post settings_backup_key_path }
    assert_redirected_to settings_backups_path

    travel(BackupKeysController::REAUTH_WINDOW + 1.minute) do
      assert_no_difference('BackupEncryptionKey.count') { create_key }
      assert_redirected_to settings_backups_path
      assert ActivityLog.exists?(action: 'backup_key_create_denied')
      assert_no_difference('BackupEncryptionKey.count') { create_key(password: 'wrong-password') }
      assert_difference('BackupEncryptionKey.count', 1) { create_key(password: 'password123') }
      assert_equal 'application/pdf', response.media_type
    end
  end

  test 'nobody but a super admin can open the page, create or activate a key' do
    @owner.update!(role: 'admin')
    sign_in
    get settings_backups_path
    assert_redirected_to settings_path
    assert_no_difference('BackupEncryptionKey.count') { create_key }
    assert_redirected_to settings_path
    post activate_settings_backup_key_path, params: { check_code: 'ABCD-EFGH' }
    assert_redirected_to settings_path
    assert ActivityLog.exists?(action: 'backup_key_access_denied')
  end

  test 'signed-out visitors are sent to sign in' do
    post settings_backup_key_path, params: { acknowledge: '1' }
    assert_redirected_to login_path
    assert_equal 0, BackupEncryptionKey.count
  end

  test 'System and Settings warn while no key is active' do
    sign_in
    get settings_path
    assert_select 'a[href=?]', settings_backups_path
    assert_match(/Server backups are not encrypted yet/, response.body)
    get system_path
    assert_select '[data-backup-key-missing] a[href=?]', settings_backups_path
  end
end
