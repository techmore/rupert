# frozen_string_literal: true

require 'test_helper'
require_relative '../support/pdf_text'

# Backups must never fail silently again: the owner sees the state on the dashboard, the bell, the status bar and
# Settings → Backups, and the page walks from "off" to the first good backup.
class BackupHealthAlertsTest < ActionDispatch::IntegrationTest
  include PdfText

  CODE = /[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}/

  setup do
    @dir = Pathname(Dir.mktmpdir)
    @env = ENV['RUPERT_BACKUP_STATUS_DIR']
    ENV['RUPERT_BACKUP_STATUS_DIR'] = @dir.to_s
    BackupHealth.stubs(:alerts_enabled?).returns(true)
    @tenant = tenants(:default_tenant)
    @owner = users(:regular_user)
    @owner.update!(role: 'super_admin', password: 'password123')
    Current.tenant = @tenant
    post login_path, params: { email: @owner.email, password: 'password123' }
  end

  teardown do
    ENV['RUPERT_BACKUP_STATUS_DIR'] = @env
    FileUtils.rm_rf(@dir)
    Current.reset
  end

  def write(layer, at:, state: 'ok', message: 'encrypted snapshot ok', fingerprint: BackupEncryptionKey.current&.fingerprint)
    @dir.join("#{layer}.json").write({ layer: layer, state: state, at: at.utc.iso8601, message: message, file: '/var/backups/x.age', bytes: 41_000_000,
      kept: 30, free_bytes: 90_000_000_000, encrypted: state == 'ok', key_fingerprint: fingerprint }.to_json)
  end

  test 'with backups off the owner is told on the dashboard, the bell, Notifications and the status bar' do
    get root_path
    assert_response :success
    assert_select '[data-backup-health-banner=off]', text: /Backups are off.*Nothing is being backed up/m do
      assert_select 'a[href=?]', settings_backups_path, 'Turn on backups'
    end
    assert_select 'a.nav-utility[data-system-alerts="1"][aria-label^="Notifications, 1 alert"] span.bg-rose', '!'
    assert_select 'footer.app-statusbar [data-vital=backup][data-backup-health=off].vital-alert', text: 'Backups off'
    get notifications_path
    assert_select '[data-system-alert]', /Backups are off/ do
      assert_select 'a[href=?]', settings_backups_path, 'Turn on backups'
    end
  end

  test 'people who cannot turn backups on are not shown the alarm' do
    @owner.update!(role: 'admin')
    get root_path
    assert_response :success
    assert_select '[data-backup-health-banner]', false
    assert_select 'a.nav-utility[data-system-alerts="0"]'
  end

  test 'turning backups on: kit, check code, first backup, and the alarm clears' do
    write('frequent', at: 1.minute.ago, state: 'failed', message: 'refused: no active backup key', fingerprint: '')
    post settings_backup_key_path, params: { acknowledge: '1' }
    assert_equal 'application/pdf', response.media_type
    code = pdf_text(response.body)[CODE]
    pending = BackupEncryptionKey.last

    get settings_backups_path(format: :json)
    assert_equal ":#{pending.id}:off", response.parsed_body['signature'], 'the page poller sees the kit was made and reloads'
    get settings_backups_path
    assert_select '#backup-key[data-backup-health=off]'
    assert_select '#backup-key-pending h2', 'Step 2 of 2: confirm you saved the recovery kit'
    assert_select '#backup-key-pending', text: /rupert-backup-recovery-kit-#{pending.fingerprint.delete(' ')}\.pdf/
    assert_select '#backup-key-pending input[type=submit][value=?]', 'Start backups'
    assert_select '#backup-key-create input[type=submit][value=?]', 'Make a new recovery kit'

    post activate_settings_backup_key_path, params: { check_code: code }
    assert_redirected_to settings_backups_path
    follow_redirect!
    assert_select '.flash-notice', text: /Backups are on\. The first encrypted backup is made within five minutes/
    assert_select '#backup-key[data-backup-health=starting]', text: /The first encrypted backup is being made/
    assert_select '[data-controller=backup-status][data-backup-status-poll-value=true]'
    assert_select '[data-last-good-backup]', text: /None yet/
    get root_path
    assert_select '[data-backup-health-banner]', false, 'no alarm while the first backup is due'
    assert_select 'footer.app-statusbar [data-vital=backup][data-backup-health=starting]', text: 'First backup pending'

    write('frequent', at: 2.minutes.ago)
    get settings_backups_path
    assert_select '#backup-key[data-backup-health=ok] h2', 'Backups are working'
    assert_select '[data-controller=backup-status][data-backup-status-poll-value=false]'
    assert_select '[data-last-good-backup]', text: /2 minutes ago.*Encrypted and integrity-checked/m
    assert_select '[data-backup-verified]', text: /Not set up on this server/
    assert_select '#backup-key-create h2', 'Replace the backup key'
    assert_select '[data-backup-extra=offsite][data-backup-state=missing]', text: /Not set up/
    get root_path
    assert_select 'a.nav-utility[data-system-alerts="0"]'
    assert_select 'footer.app-statusbar [data-vital=backup][data-backup-health=ok]', text: /Backup 2 minutes ago/
  end

  test 'a backup that stops later raises the alarm again with the reason' do
    pair = BackupEncryption::AgeKey.generate
    key = BackupEncryptionKey.create!(recipient: pair.recipient, confirmation_digest: BackupEncryptionKey.digest('ABCD-EFGH'), activated_at: 9.days.ago)
    write('frequent', at: 3.hours.ago, fingerprint: key.fingerprint)
    write('local', at: 2.hours.ago, fingerprint: key.fingerprint)
    get root_path
    assert_select '[data-backup-health-banner=attention]', text: /Backups need attention.*Rolling snapshot has not run since about 3 hours ago/m do
      assert_select 'a[href=?]', settings_backups_path, 'Open Backups'
    end
    get settings_backups_path
    assert_select '#backup-key[data-backup-health=attention] .flash-alert', text: /Last good backup: about 2 hours ago/
  end
end
