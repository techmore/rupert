# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/pdf_text'

class BackupEncryption::RecoveryKitPdfTest < ActiveSupport::TestCase
  include PdfText

  setup do
    @pair = BackupEncryption::AgeKey.generate
    @key = BackupEncryptionKey.create!(recipient: @pair.recipient, confirmation_digest: BackupEncryptionKey.digest('ABCD-EFGH'))
    @kit = BackupEncryption::RecoveryKitPdf.new(identity: @pair.identity, key: @key, check_code: 'ABCD-EFGH',
      workspace: 'Test Co', created_by: 'Owner')
    @pdf = @kit.render
    @text = pdf_text(@pdf)
  end

  test 'the kit holds the private key, fingerprint, check code and the database encryption keys' do
    assert @pdf.start_with?('%PDF-1')
    lines = @text.lines.map(&:strip)
    assert_includes lines, @pair.identity, 'the private key is on one unbroken line'
    assert_includes @text, "Key fingerprint: #{@key.fingerprint}"
    assert_includes @text, @key.recipient
    assert_includes lines, 'ABCD-EFGH'
    BackupEncryption::RecoveryKitPdf.current_encryption_keys.each do |name, value|
      assert_includes lines, name
      assert_includes lines, value
    end
    assert_includes @text, 'bin/backup-decrypt'
    assert_includes @text, 'Rupert backup recovery kit — Test Co'
  end

  test 'it is titled as a recovery kit note and has no form fields or login pair' do
    assert_equal 'Rupert backup recovery kit — Test Co', @kit.title
    assert_includes @text, 'SECURE NOTE (not a login)'
    assert_includes @text, 'Do not attach it to the rupertpos.com login entry'
    %w[/AcroForm /Widget /FT /Annot /Annots].each { |marker| assert_not_includes @pdf, marker }
    assert_no_match(/(Username|User name|E-?mail|Password)\s*:/i, @text, 'no login-style labels for a password manager to pick up')
    assert_match(/\Arupert-backup-recovery-kit-[0-9a-f]{16}\.pdf\z/, @kit.filename)
  end

  test 'the private key is not in the PDF metadata' do
    info = @pdf[%r{/Title.*?>>}m].to_s
    assert_not_includes info, 'AGE-SECRET-KEY'
  end
end
