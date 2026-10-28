# frozen_string_literal: true

require 'test_helper'

class BackupStatusTest < ActiveSupport::TestCase
  setup do
    @dir = Pathname(Dir.mktmpdir)
    @env = ENV['RUPERT_BACKUP_STATUS_DIR']
    ENV['RUPERT_BACKUP_STATUS_DIR'] = @dir.to_s
    @now = Time.utc(2026, 10, 22, 12, 0, 0)
    BackupEncryptionKey.stubs(:current).returns(stub(fingerprint: 'fixture-key'))
  end

  teardown do
    ENV['RUPERT_BACKUP_STATUS_DIR'] = @env
    FileUtils.rm_rf(@dir)
  end

  def write(layer, at:, state: 'ok', **fields)
    @dir.join("#{layer}.json").write({ layer: layer, state: state, at: at.utc.iso8601, message: 'ok', file: '/x', bytes: 1, kept: 2, free_bytes: 3,
      encrypted: true, key_fingerprint: 'fixture-key' }.merge(fields).to_json)
  end

  test 'every layer is listed in order and a layer without a file is missing' do
    layers = BackupStatus.layers
    assert_equal %w[frequent local offhost offsite verify restore], layers.map(&:key)
    assert layers.all? { |layer| layer.state(@now) == 'missing' }
    assert_equal 'missing', BackupStatus.summary(layers, now: @now)
  end

  test 'fresh reports are ok, old ones are stale per layer, failed wins, and the summary is the worst state' do
    write('frequent', at: @now - 4.minutes)
    write('local', at: @now - 8.hours)                 # stale: 6-hourly layer allowed 7 hours
    write('offhost', at: @now - 6.hours)               # still ok at 6 hours
    write('offsite', at: @now - 40.hours)              # ok: a laptop mirror is allowed 48 hours
    write('verify', at: @now - 7.days)
    write('restore', at: @now - 30.days)
    by_key = BackupStatus.layers.index_by(&:key)
    assert_equal 'ok', by_key['frequent'].state(@now)
    assert_equal 'stale', by_key['local'].state(@now)
    assert_equal 'ok', by_key['offhost'].state(@now)
    assert_equal 'ok', by_key['offsite'].state(@now)
    assert_equal 'ok', by_key['verify'].state(@now)
    assert_equal 'ok', by_key['restore'].state(@now)
    assert_equal 'stale', BackupStatus.summary(BackupStatus.layers, now: @now)

    write('restore', at: @now - 1.day, key_fingerprint: 'retired-key')
    assert_equal 'stale', BackupStatus.layers.find { |layer| layer.key == 'restore' }.state(@now), 'a rotated key needs a new drill'
    assert_match(/active backup key/, BackupStatus.layers.find { |layer| layer.key == 'restore' }.evidence_issue(@now))

    write('frequent', at: @now - 1.minute, state: 'unexpected')
    assert_equal 'failed', BackupStatus.layers.first.state(@now)

    write('frequent', at: @now + 1.day)
    assert_equal 'failed', BackupStatus.layers.first.state(@now), 'future timestamps cannot prove freshness'

    write('offhost', at: @now - 1.minute, encrypted: nil)
    assert_equal 'failed', BackupStatus.layers.find { |layer| layer.key == 'offhost' }.state(@now)
    assert_match(/does not confirm/, BackupStatus.layers.find { |layer| layer.key == 'offhost' }.evidence_issue(@now))
    write('offsite', at: @now - 1.minute, encrypted: false)
    assert_equal 'failed', BackupStatus.layers.find { |layer| layer.key == 'offsite' }.state(@now)

    write('frequent', at: @now - 1.minute, state: 'failed', message: 'skipped: 900 MB free, need 5300 MB')
    layers = BackupStatus.layers
    assert_equal 'failed', layers.first.state(@now)
    assert_equal 'skipped: 900 MB free, need 5300 MB', layers.first.report.message
    assert_equal 'failed', BackupStatus.summary(layers, now: @now)
  end

  test 'all fresh is ok and malformed or unreadable files count as never reported' do
    %w[frequent local offhost offsite verify restore].each { |layer| write(layer, at: @now - 1.minute) }
    assert_equal 'ok', BackupStatus.summary(BackupStatus.layers, now: @now)

    @dir.join('frequent.json').write('not json')
    @dir.join('local.json').write('[1,2]')
    @dir.join('offhost.json').write({ state: 'ok', at: 'yesterday-ish', encrypted: true }.to_json)
    layers = BackupStatus.layers.index_by(&:key)
    assert_equal 'missing', layers['frequent'].state(@now)
    assert_equal 'missing', layers['local'].state(@now)
    assert_equal 'stale', layers['offhost'].state(@now), 'a report without a parseable time cannot be trusted as fresh'
  end
end
