# frozen_string_literal: true

require 'test_helper'

class BackupEncryptionKeyTest < ActiveSupport::TestCase
  def make(code = 'ABCD-EFGH')
    BackupEncryptionKey.create!(recipient: BackupEncryption::AgeKey.generate.recipient, confirmation_digest: BackupEncryptionKey.digest(code))
  end

  test 'a key starts pending and is not used until activated' do
    key = make
    assert_equal 'pending', key.state
    assert_nil BackupEncryptionKey.current
    assert_equal BackupEncryption::AgeKey.fingerprint(key.recipient), key.fingerprint
  end

  test 'the check code is matched loosely on case and separators' do
    key = make('K7QW-2MZP')
    assert key.code_matches?('k7qw2mzp')
    assert key.code_matches?(' K7QW-2MZP ')
    assert_not key.code_matches?('K7QW-2MZQ')
    assert_not key.code_matches?('')
  end

  test 'activating a new key retires the old one, which stays listed' do
    old = make
    old.activate!(actor: nil)
    assert_equal old, BackupEncryptionKey.current
    new_key = make('WXYZ-2345')
    new_key.activate!(actor: nil)
    assert_equal new_key, BackupEncryptionKey.current
    assert_equal 'retired', old.reload.state
    assert_equal 2, BackupEncryptionKey.count
  end

  test 'only age X25519 public keys are accepted' do
    key = BackupEncryptionKey.new(recipient: 'age1notakey', confirmation_digest: 'x')
    assert_not key.valid?
    key.recipient = "AGE-SECRET-KEY-1#{'Q' * 58}"
    assert_not key.valid?, 'a private key must never be stored as the recipient'
  end

  test 'a pending key expires after an hour' do
    key = make
    travel 61.minutes do
      assert key.expired?
      assert_equal 'expired', key.state
    end
  end
end
