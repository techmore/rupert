# frozen_string_literal: true

require 'test_helper'

# BackupHealth: the single plain answer shown on Settings → Backups, the bell, the dashboard and the status bar.
class BackupHealthTest < ActiveSupport::TestCase
  REFUSED = 'refused: no active backup key, so no unencrypted snapshot was written. Create one in Settings → Backups.'

  setup do
    @dir = Pathname(Dir.mktmpdir)
    @env = ENV['RUPERT_BACKUP_STATUS_DIR']
    ENV['RUPERT_BACKUP_STATUS_DIR'] = @dir.to_s
    @now = Time.utc(2026, 11, 11, 18, 0, 0)
  end

  teardown do
    ENV['RUPERT_BACKUP_STATUS_DIR'] = @env
    FileUtils.rm_rf(@dir)
  end

  def write(layer, at:, state: 'ok', message: 'ok', encrypted: true, fingerprint: @key&.fingerprint)
    @dir.join("#{layer}.json").write({ layer: layer, state: state, at: at.utc.iso8601, message: message, file: '/x', bytes: 1, kept: 2,
      free_bytes: 3, encrypted: encrypted, key_fingerprint: fingerprint }.to_json)
  end

  def activate_key(at)
    pair = BackupEncryption::AgeKey.generate
    @key = BackupEncryptionKey.create!(recipient: pair.recipient, confirmation_digest: BackupEncryptionKey.digest('ABCD-EFGH'), activated_at: at)
  end

  def health = BackupHealth.new(now: @now)

  test 'without an active key backups are off, whatever the scripts last said' do
    write('frequent', at: @now - 2.minutes, state: 'failed', message: REFUSED, encrypted: false)
    assert_equal :off, health.state
    assert health.alert?
    assert_equal 'Backups are off', health.title
    assert_equal 'Turn on backups', health.link_label
    assert_match(/Nothing is being backed up/, health.summary)
    assert_nil health.last_good_at
  end

  test 'a key that was just turned on waits for each layer once instead of alarming on the old refusals' do
    activate_key(@now - 2.minutes)
    write('frequent', at: @now - 3.minutes, state: 'failed', message: REFUSED, encrypted: false)
    write('local', at: @now - 4.hours, state: 'failed', message: REFUSED, encrypted: false)
    write('verify', at: @now - 3.days, state: 'failed', message: 'no encrypted backup found')
    assert_equal :starting, health.state
    assert_not health.alert?
    assert_equal %w[frequent local verify], health.waiting.map(&:key)

    write('frequent', at: @now - 1.minute)
    assert_equal :ok, health.state
    assert_equal (@now - 1.minute).to_i, health.last_good_at.to_i
    assert_nil health.verified_at
    assert_equal %w[local verify], health.waiting.map(&:key)
    assert_match(/Last good backup: 1 minute ago/, health.summary)
  end

  test 'a layer that still has not run after one interval of its schedule is a problem' do
    activate_key(@now - 30.minutes)
    write('frequent', at: @now - 31.minutes, state: 'failed', message: REFUSED, encrypted: false)
    assert_equal :attention, health.state
    assert health.alert?
    assert_equal %w[frequent], health.problems.map(&:key)
    assert_match(/Rolling snapshot failed 31 minutes ago: refused: no active backup key/, health.summary)
    assert_match(/There is no good backup yet/, health.summary)
  end

  test 'a failure reported after the key was turned on alarms at once, and a stale layer says when it last ran' do
    activate_key(@now - 10.days)
    write('frequent', at: @now - 1.minute, state: 'failed', message: 'skipped: 100 MB free on /var/backups, need 6000 MB. Free disk space.')
    write('local', at: @now - 9.hours)
    assert_equal :attention, health.state
    assert_equal %w[frequent local], health.problems.map(&:key)
    assert_match(/Rolling snapshot failed 1 minute ago: skipped: 100 MB free/, health.summary)
    assert_match(/Local backup set has not run since about 9 hours ago \(expected every 6 hours\)/, health.summary)
    assert_equal 'Open Backups', health.link_label
  end

  test 'healthy: fresh encrypted backups, the weekly check passed, and extra layers never alarm' do
    activate_key(@now - 10.days)
    write('frequent', at: @now - 3.minutes)
    write('local', at: @now - 2.hours)
    write('offhost', at: @now - 2.hours)
    write('verify', at: @now - 2.days)
    write('offsite', at: @now - 30.days)
    state = health
    assert_equal :ok, state.state
    assert_not state.alert?
    assert_equal (@now - 3.minutes).to_i, state.last_good_at.to_i
    assert_equal (@now - 2.days).to_i, state.verified_at.to_i
    assert_equal({ 'offsite' => 'stale', 'restore' => 'missing' }, state.extras.to_h { |check| [check.key, check.state] })
  end

  test 'the off-host copy and weekly check count only once installed, and a report without encryption evidence fails' do
    activate_key(@now - 10.days)
    write('frequent', at: @now - 3.minutes)
    write('local', at: @now - 2.hours)
    assert_equal :ok, health.state, 'never-reported host layers are not installed, not failing'
    write('offhost', at: @now - 1.hour, encrypted: false)
    assert_equal :attention, health.state
    assert_match(/does not confirm an age-encrypted backup/, health.summary)
  end

  test 'alerts are for super admins on real servers only' do
    owner = users(:regular_user)
    owner.update!(role: 'super_admin')
    assert_nil BackupHealth.alert_for(owner), 'off in the test environment unless switched on'
    BackupHealth.stubs(:alerts_enabled?).returns(true)
    assert_equal :off, BackupHealth.alert_for(owner).state
    owner.update!(role: 'admin')
    assert_nil BackupHealth.alert_for(owner)
    assert_nil BackupHealth.alert_for(nil)
  end

  test 'the hourly job notifies each instance owner once a day while backups are off' do
    Current.tenant = tenants(:default_tenant)
    owner = users(:regular_user)
    owner.update!(role: 'super_admin')
    assert_no_difference('Notification.unscoped.count') { BackupHealthAlertJob.perform_now }
    BackupHealth.stubs(:alerts_enabled?).returns(true)
    assert_difference(-> { Notification.unscoped.where(user_id: owner.id, kind: 'backup_health').count }, 1) do
      2.times { BackupHealthAlertJob.perform_now }
    end
    note = Notification.unscoped.find_by!(user_id: owner.id, kind: 'backup_health')
    assert_equal 'Backups are off', note.title
    assert_equal '/settings/backups', note.url
    travel(1.day) { assert_difference(-> { Notification.unscoped.where(kind: 'backup_health', user_id: owner.id).count }, 1) { BackupHealthAlertJob.perform_now } }

    activate_key(2.minutes.ago)
    assert_no_difference('Notification.unscoped.count') { BackupHealthAlertJob.perform_now }
  ensure
    Current.reset
  end
end
