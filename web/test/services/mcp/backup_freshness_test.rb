# frozen_string_literal: true

require 'test_helper'

class McpBackupFreshnessTest < ActiveSupport::TestCase
  test 'local snapshot inventory includes age database archives and excludes sidecars' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'rupert-20261027-120000.sqlite3.gz.age'), 'encrypted database')
      File.write(File.join(dir, 'settings-20261027-120000.sql.age'), 'encrypted settings')
      File.write(File.join(dir, 'env-20261027-120000.age'), 'encrypted environment')
      File.write(File.join(dir, 'rupert-20261027-120000.sqlite3.gz.age.sha256'), 'checksum')
      snapshot = Mcp::Tools::BackupFreshness.allocate.send(:local_snapshots, dir)
      assert_equal 1, snapshot[:files]
      assert_equal 'rupert-20261027-120000.sqlite3.gz.age', snapshot.dig(:newest, :name)
    end
  end
end
