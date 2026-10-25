# frozen_string_literal: true

require 'prawn'

Prawn::Fonts::AFM.hide_m17n_warning = true

module BackupEncryption
  # The owner's backup recovery kit (#421): everything a restore needs that is not in the backup itself.
  #   - the age private key that decrypts the backups (the server keeps only the public half);
  #   - the Active Record encryption keys that decrypt encrypted columns and settings in a restored database;
  #   - the key fingerprint (also written next to every backup file), creation date, the activation check code and
  #     the restore steps.
  #
  # Meant to be stored as a SEPARATE secure note in a password manager. It deliberately has no form fields and no
  # username/password pair, and its title is not the site's name, so a password manager does not offer to save it as
  # the rupertpos.com login (sign-in is with Google; there is no site password).
  #
  # Rendered in memory and sent once; nothing here writes to disk. Secrets are in Courier without kerning so each one
  # is a single unbroken string that copies cleanly out of the PDF.
  class RecoveryKitPdf
    INK = '1C1917'
    MOCHA = '57534E'
    ROSE = '9F1239'
    ENCRYPTION_ENV = {
      'RAILS_ENCRYPTION_PRIMARY_KEY' => :primary_key,
      'RAILS_ENCRYPTION_DETERMINISTIC_KEY' => :deterministic_key,
      'RAILS_ENCRYPTION_KEY_DERIVATION_SALT' => :key_derivation_salt
    }.freeze

    def self.title_for(workspace) = "Rupert backup recovery kit — #{workspace}"

    # identity: the age private key (AGE-SECRET-KEY-1…). key: the BackupEncryptionKey row (public half).
    def initialize(identity:, key:, check_code:, workspace:, created_by:, encryption_keys: self.class.current_encryption_keys)
      @identity = identity
      @key = key
      @check_code = check_code
      @workspace = workspace.presence || 'Rupert'
      @created_by = created_by
      @encryption_keys = encryption_keys
    end

    def self.current_encryption_keys
      config = Rails.application.config.active_record.encryption
      ENCRYPTION_ENV.transform_values { |attr| Array(config.public_send(attr)).join(',') }
    end

    def title = self.class.title_for(@workspace)
    def filename = "rupert-backup-recovery-kit-#{@key.fingerprint.delete(' ')}.pdf"
    def render = document.render

    def document
      Prawn::Document.new(page_size: 'LETTER', margin: 48, info: { Title: title, Creator: 'Rupert' }).tap do |pdf|
        pdf.default_kerning(false)
        pdf.font('Helvetica')
        header(pdf)
        how_to_store(pdf)
        backup_key(pdf)
        encryption_keys(pdf)
        restore_steps(pdf)
      end
    end

    private

    def header(pdf)
      pdf.fill_color(INK)
      pdf.text(title, size: 18, style: :bold)
      pdf.move_down(4)
      pdf.fill_color(MOCHA)
      pdf.text("Created #{@key.created_at.utc.strftime('%b %-d, %Y %H:%M UTC')} by #{@created_by}", size: 10)
      pdf.text("Key fingerprint: #{@key.fingerprint}", size: 10)
      pdf.move_down(10)
      pdf.fill_color(ROSE)
      pdf.text('This page is shown once. Rupert does not keep the private key: if this kit is lost, backups made ' \
               'with this key cannot be opened by anyone.', size: 10, style: :bold)
      pdf.fill_color(INK)
      pdf.move_down(12)
    end

    def how_to_store(pdf)
      section(pdf, 'How to store it')
      bullets(pdf, [
        "Save this PDF in your password manager as a new SECURE NOTE (not a login) titled \"#{title}\".",
        'Do not attach it to the rupertpos.com login entry. Sign-in uses Google, so there is no site password to ' \
        'save; this note holds backup keys only.',
        'Keep a second copy somewhere offline (printed, in a safe). Never email it or keep it on the Rupert server.',
        'To start using this key, type the check code below on Settings > Backups within the hour. Until then ' \
        'backups keep using the previous key.'
      ])
      pdf.text('Check code', size: 9, style: :bold)
      secret(pdf, @check_code)
      pdf.move_down(8)
    end

    def backup_key(pdf)
      section(pdf, 'Backup decryption key (age private key)')
      pdf.text('Decrypts the .age backup files whose ".key" file shows the fingerprint above.', size: 10, color: MOCHA)
      secret(pdf, @identity)
      pdf.text("Public key (already on the server, not secret): #{@key.recipient}", size: 8, color: MOCHA)
      pdf.move_down(12)
    end

    def encryption_keys(pdf)
      section(pdf, 'Database encryption keys (Active Record)')
      pdf.text('A restored database reads its encrypted settings, tokens and uploads only with these exact values. ' \
               'Put them in the restored server\'s environment file unchanged.', size: 10, color: MOCHA)
      @encryption_keys.each do |name, value|
        pdf.move_down(4)
        pdf.text(name, size: 9, style: :bold)
        secret(pdf, value)
      end
      pdf.move_down(8)
    end

    def restore_steps(pdf)
      section(pdf, 'Restore steps')
      numbered(pdf, [
        'On a trusted computer with age installed (apt install age), copy the backup set: rupert-<stamp>.sqlite3.gz.age ' \
        'and its .sha256 and .key files.',
        'Check the .key file shows the fingerprint on this kit. If not, use the kit whose fingerprint matches.',
        'Put the private key above in a file only you can read (or paste it when asked), then run from the Rupert ' \
        'source: bin/backup-decrypt --identity-file KEYFILE --out restored.sqlite3 rupert-<stamp>.sqlite3.gz.age ' \
        '(or --identity-stdin). It checks the digest, decrypts, decompresses and runs the SQLite integrity checks.',
        'Never put the key on the command line itself: it would be saved in shell history.',
        'Follow docs/ops/backups.md "Restore": restore to a copy first, set the three database encryption keys ' \
        'above in the environment file, then plan a maintenance window for the live server.',
        'Delete the key file and any decrypted copy when you are done.'
      ])
    end

    def section(pdf, label)
      pdf.text(label, size: 12, style: :bold)
      pdf.move_down(4)
    end

    def secret(pdf, value)
      pdf.move_down(2)
      pdf.font('Courier') { pdf.text(value.to_s, size: 9) }
      pdf.move_down(4)
    end

    def bullets(pdf, items)
      items.each { |item| pdf.text("•  #{item}", size: 10, indent_paragraphs: 0) }
      pdf.move_down(12)
    end

    def numbered(pdf, items)
      items.each_with_index { |item, i| pdf.text("#{i + 1}.  #{item}", size: 10) }
    end
  end
end
