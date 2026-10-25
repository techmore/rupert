# frozen_string_literal: true

# Rewrites rows stored before their columns gained `encrypts` (#421) so every value on disk becomes ciphertext.
# Active Record keeps reading the old plaintext (support_unencrypted_data), so nothing breaks before this runs;
# it only closes the gap for rows written earlier. Run through `bin/rails ops:encrypt_sensitive_fields`.
#
# A dry run (the default) reads and counts only. With write: true each plaintext row is rewritten in place with
# update_all: no validations, callbacks or updated_at change, and issued 1099 rows (read-only records) are covered
# too. Rows already encrypted are skipped, so it is safe to run again.
class SensitiveFieldEncryption
  MODELS = %w[
    TeamChat::Message TeamChat::Attachment FeedbackAttachment
    People::PayRate People::PayRun People::Payslip People::Employee
    Finance::TaxPayee Finance::TaxFormFiling
  ].freeze
  BATCH = 200
  # Rows that carry file bytes are loaded a few at a time.
  BATCH_FOR = { 'TeamChat::Attachment' => 10, 'FeedbackAttachment' => 20 }.freeze

  Result = Struct.new(:model, :attributes, :checked, :plaintext, :rewritten, keyword_init: true) do
    def line(write)
      "#{model}: #{checked} rows checked, #{plaintext} with plaintext #{attributes.join('/')}, " \
        "#{write ? "#{rewritten} encrypted" : 'nothing written (dry run)'}"
    end
  end

  def self.call(write: false, tenant_id: nil, models: MODELS)
    models.map { |name| new(name.constantize, write: write, tenant_id: tenant_id).run }
  end

  def initialize(model, write:, tenant_id:)
    @model = model
    @write = write
    @tenant_id = tenant_id.presence
    @attributes = Array(model.encrypted_attributes).map(&:to_s)
  end

  def run
    result = Result.new(model: @model.name, attributes: @attributes, checked: 0, plaintext: 0, rewritten: 0)
    scope.find_in_batches(batch_size: BATCH_FOR.fetch(@model.name, BATCH)) do |rows|
      pending = rows.select { |row| plaintext?(row) }
      result.checked += rows.size
      result.plaintext += pending.size
      next unless @write && pending.any?

      @model.transaction { pending.each { |row| result.rewritten += rewrite(row) } }
    end
    result
  end

  private

  # Every row of the model, across tenants unless one is named; default scopes (tenant, merged profiles) are lifted.
  def scope
    rows = @model.unscoped
    @tenant_id ? rows.where(tenant_id: @tenant_id) : rows
  end

  def plaintext?(row)
    @attributes.any? { |name| !row.read_attribute_before_type_cast(name).nil? && !row.encrypted_attribute?(name) }
  end

  # The decrypted (or legacy plaintext) values written back through the encrypted types.
  def rewrite(row)
    @model.unscoped.where(id: row.id).update_all(@attributes.index_with { |name| row[name] })
  end
end
