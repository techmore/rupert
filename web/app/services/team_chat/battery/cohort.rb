# frozen_string_literal: true

require 'digest'
require 'json'

module TeamChat
  class Battery
    # A private, encrypted set of reference evidence shared by model runs.
    # The live evidence is checked again before grading; changed evidence is
    # ungraded, so a model is never scored against a different snapshot.
    class Cohort
      class Error < StandardError; end
      VERSION = 1

      def self.item_digest(item)
        Digest::SHA256.hexdigest(JSON.generate(item.to_h))
      end

      def self.capture(user:, items:)
        raise Error, 'no questions' if items.empty?
        raise Error, 'duplicate question IDs' unless items.map(&:id).uniq.size == items.size

        entries = items.to_h do |item|
          reference = yield(item).to_s
          raise Grader::Error, 'no reference or authored expectation' if reference.blank? && item.expect.blank?

          [item.id.to_s, { 'item_digest' => item_digest(item), 'reference' => reference }]
        rescue Grader::Error => e
          [item.id.to_s, { 'item_digest' => item_digest(item), 'error' => e.message.first(160) }]
        end
        new('version' => VERSION, 'tenant_id' => user.tenant_id.to_s, 'user_id' => user.id.to_s,
          'date' => Date.current.iso8601, 'created_at' => Time.current.iso8601,
          'rubric_digest' => Digest::SHA256.hexdigest(Grader::PROMPT), 'items' => entries)
      end

      def self.load_file(path, user:)
        payload = ActiveRecord::Encryption.encryptor.decrypt(File.binread(path))
        cohort = new(JSON.parse(payload))
        raise Error, 'cohort belongs to another requester or workspace' unless cohort.for_user?(user)

        cohort
      rescue ActiveRecord::Encryption::Errors::Base, JSON::ParserError
        raise Error, 'cohort cannot be decrypted or parsed'
      end

      def initialize(payload)
        @payload = payload
        raise Error, 'unsupported cohort version' unless @payload['version'] == VERSION
        raise Error, 'invalid cohort items' unless @payload['items'].is_a?(Hash)
      end

      def id = Digest::SHA256.hexdigest(JSON.generate(@payload))[0, 16]
      def for_user?(user) = @payload['tenant_id'] == user.tenant_id.to_s && @payload['user_id'] == user.id.to_s
      def size = @payload['items'].size
      def ungradable = @payload['items'].values.count { |entry| entry['error'].present? }

      def save_file(path)
        encrypted = ActiveRecord::Encryption.encryptor.encrypt(JSON.generate(@payload))
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(encrypted) }
      end

      def reference(item)
        raise Grader::Error, 'cohort date has changed' unless @payload['date'] == Date.current.iso8601
        raise Grader::Error, 'grading rubric changed since cohort capture' unless @payload['rubric_digest'] == Digest::SHA256.hexdigest(Grader::PROMPT)
        entry = @payload['items'][item.id.to_s]
        raise Grader::Error, 'question absent or changed since cohort capture' unless entry && entry['item_digest'] == self.class.item_digest(item)
        raise Grader::Error, "cohort reference unavailable: #{entry['error']}" if entry['error'].present?

        current = yield.to_s
        raise Grader::Error, 'reference changed since cohort capture' unless ActiveSupport::SecurityUtils.secure_compare(
          Digest::SHA256.hexdigest(current), Digest::SHA256.hexdigest(entry.fetch('reference'))
        )

        entry.fetch('reference')
      end
    end
  end
end
