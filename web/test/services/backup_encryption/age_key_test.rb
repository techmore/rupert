# frozen_string_literal: true

require 'test_helper'
require 'open3'

class BackupEncryption::AgeKeyTest < ActiveSupport::TestCase
  AgeKey = BackupEncryption::AgeKey

  def age? = system('command -v age >/dev/null 2>&1') && system('command -v age-keygen >/dev/null 2>&1')

  test 'Bech32 matches the BIP-173 reference vectors' do
    assert_equal ['a', ''], AgeKey.decode('a12uel5l')
    hrp, = AgeKey.decode('abcdef1qpzry9x8gf2tvdw0s3jn54khce6mua7lmqqqxw')
    assert_equal 'abcdef', hrp
    assert_raises(ArgumentError) { AgeKey.decode('a12uel5m') }
  end

  test 'a generated pair is an age X25519 recipient and identity that belong together' do
    pair = AgeKey.generate
    assert AgeKey.valid_recipient?(pair.recipient), pair.recipient
    assert_match(/\AAGE-SECRET-KEY-1[0-9A-Z]{58}\z/, pair.identity)
    assert_equal pair.recipient, AgeKey.recipient_for(pair.identity)
    assert_match(/\A[0-9a-f]{4}( [0-9a-f]{4}){3}\z/, pair.fingerprint)
    assert_not_equal AgeKey.generate.recipient, pair.recipient
    assert_not_includes pair.inspect, 'SECRET', 'inspect never prints the private key'
    assert_not_includes pair.to_s, pair.identity
  end

  test 'the fingerprint is the one the shell scripts compute' do
    recipient = AgeKey.generate.recipient
    shell = `printf '%s' '#{recipient}' | sha256sum | cut -c1-16 | sed -E 's/(....)/\\1 /g; s/ $//'`.strip
    assert_equal shell, AgeKey.fingerprint(recipient)
  end

  test 'age-keygen agrees, and age round-trips and rejects tampered ciphertext' do
    skip 'age is not installed (apt-get install age)' unless age?
    pair = AgeKey.generate
    out, status = Open3.capture2('age-keygen', '-y', stdin_data: "#{pair.identity}\n")
    assert status.success?
    assert_equal pair.recipient, out.strip

    plain = Random.bytes(50_000)
    cipher, status = Open3.capture2('age', '-r', pair.recipient, stdin_data: plain, binmode: true)
    assert status.success?
    assert cipher.start_with?("age-encryption.org/v1\n")
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'x.age')
      File.binwrite(path, cipher)
      back, status = Open3.capture2('age', '-d', '-i', '-', path, stdin_data: "#{pair.identity}\n", binmode: true)
      assert status.success?
      assert_equal plain, back.b

      tampered = cipher.dup
      tampered.setbyte(tampered.bytesize - 100, tampered.getbyte(tampered.bytesize - 100) ^ 1)
      File.binwrite(path, tampered)
      _, err, status = Open3.capture3('age', '-d', '-i', '-', path, stdin_data: "#{pair.identity}\n", binmode: true)
      assert_not status.success?, 'a flipped ciphertext bit must fail authentication'
      assert_predicate err, :present?

      File.binwrite(path, cipher)
      _, _, status = Open3.capture3('age', '-d', '-i', '-', path, stdin_data: "#{AgeKey.generate.identity}\n", binmode: true)
      assert_not status.success?, 'another key cannot decrypt'
    end
  end
end
