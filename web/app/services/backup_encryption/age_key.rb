# frozen_string_literal: true

require 'openssl'
require 'digest'

module BackupEncryption
  # An age (https://age-encryption.org/v1) X25519 key pair, made in memory with OpenSSL and encoded exactly as
  # age-keygen does: the recipient is Bech32 with HRP "age", the identity is Bech32 with HRP "age-secret-key-",
  # upper-cased. The backup scripts encrypt with the `age` CLI to the recipient; only the identity can decrypt.
  #
  # The identity is returned to the caller and never written anywhere by this class. The recovery kit is the only
  # place it ends up (BackupKeysController).
  class AgeKey
    CHARSET = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l'
    GENERATOR = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3].freeze
    RECIPIENT_HRP = 'age'
    IDENTITY_HRP = 'age-secret-key-'
    # What the scripts accept before passing a recipient to `age -r` (also checked in bin/backup.sh).
    RECIPIENT_FORMAT = /\Aage1[#{CHARSET}]{58}\z/

    Pair = Struct.new(:recipient, :identity, keyword_init: true) do
      def fingerprint = AgeKey.fingerprint(recipient)
      def inspect = "#<#{self.class.name} recipient=#{recipient}>" # never print the identity
      alias_method :to_s, :inspect
    end

    class << self
      def generate
        key = OpenSSL::PKey.generate_key('X25519')
        Pair.new(recipient: encode(RECIPIENT_HRP, key.raw_public_key),
          identity: encode(IDENTITY_HRP, key.raw_private_key).upcase)
      end

      # The recipient for an identity string (what `age-keygen -y` prints).
      def recipient_for(identity)
        hrp, data = decode(identity.to_s.strip.downcase)
        raise ArgumentError, 'not an age identity' unless hrp == IDENTITY_HRP && data.bytesize == 32

        encode(RECIPIENT_HRP, OpenSSL::PKey.new_raw_private_key('X25519', data).raw_public_key)
      end

      # Short, stable label for a recipient, printed on the recovery kit and next to every backup file
      # (`printf %s "$recipient" | sha256sum | cut -c1-16` in the scripts).
      def fingerprint(recipient)
        Digest::SHA256.hexdigest(recipient.to_s)[0, 16].scan(/..../).join(' ')
      end

      def valid_recipient?(recipient) = RECIPIENT_FORMAT.match?(recipient.to_s)

      def encode(hrp, bytes)
        data = convert_bits(bytes.bytes, 8, 5, pad: true)
        checksum = create_checksum(hrp, data)
        "#{hrp}1#{(data + checksum).map { |value| CHARSET[value] }.join}"
      end

      def decode(string)
        separator = string.rindex('1')
        raise ArgumentError, 'not Bech32' if separator.nil? || separator.zero? || string.length - separator < 7

        hrp = string[0...separator]
        values = string[(separator + 1)..].chars.map { |char| CHARSET.index(char) || raise(ArgumentError, 'not Bech32') }
        raise ArgumentError, 'Bech32 checksum mismatch' unless polymod(expand_hrp(hrp) + values) == 1

        [hrp, convert_bits(values[0...-6], 5, 8, pad: false).pack('C*')]
      end

      private

      def polymod(values)
        values.reduce(1) do |chk, value|
          top = chk >> 25
          chk = ((chk & 0x1ffffff) << 5) ^ value
          GENERATOR.each_with_index.reduce(chk) { |acc, (gen, i)| top[i] == 1 ? acc ^ gen : acc }
        end
      end

      def expand_hrp(hrp) = hrp.bytes.map { |c| c >> 5 } + [0] + hrp.bytes.map { |c| c & 31 }

      def create_checksum(hrp, data)
        mod = polymod(expand_hrp(hrp) + data + [0] * 6) ^ 1
        Array.new(6) { |i| (mod >> (5 * (5 - i))) & 31 }
      end

      def convert_bits(values, from, to, pad:)
        acc = 0
        bits = 0
        out = []
        maxv = (1 << to) - 1
        values.each do |value|
          acc = (acc << from) | value
          bits += from
          while bits >= to
            bits -= to
            out << ((acc >> bits) & maxv)
          end
        end
        if pad
          out << ((acc << (to - bits)) & maxv) if bits.positive?
        elsif bits >= from || ((acc << (to - bits)) & maxv).nonzero?
          raise ArgumentError, 'invalid Bech32 padding'
        end
        out
      end
    end
  end
end
