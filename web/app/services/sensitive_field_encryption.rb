# frozen_string_literal: true

# Rewrites rows stored before their columns gained `encrypts` (#421) so every value on disk becomes ciphertext.
# Active Record keeps reading the old plaintext (support_unencrypted_data), so nothing breaks before this runs;
# it only closes the gap for rows written earlier. Run through `bin/rails ops:encrypt_sensitive_fields`, and
# confirm with `bin/rails ops:encryption_status` before plaintext support is turned off
# (docs/ops/encryption-at-rest.md).
#
# Every model that declares `encrypts` is covered: the app, its modules and the engines are eager-loaded and
# each Active Record class with encrypted attributes is scanned. A new `encrypts` needs no change here.
#
# A dry run (the default) reads and counts only. With write: true each plaintext value is rewritten in place
# with update_all: no validations, callbacks or updated_at change, and read-only records (attr_readonly,
# issued 1099 filings) are covered too. Values already encrypted are skipped, so it is safe to run again.
# Rows are read as raw column values (id plus the encrypted columns only), so no record is instantiated and
# large blobs are read a few rows at a time.
class SensitiveFieldEncryption
  BATCH = 200
  # Rows whose encrypted columns carry file bytes or whole documents are loaded a few at a time.
  BLOB_BATCH = 10
  DOCUMENT_BATCH = 50
  BLOB_COLUMN = /base64|csv|\Adata\z|binary_body|text_body/
  DOCUMENT_COLUMN = /json|payload|snapshot/
  BATCH_FOR = { 'TeamChat::Attachment' => 10, 'FeedbackAttachment' => 20 }.freeze

  Target = Struct.new(:model, :attributes, :skipped, keyword_init: true)

  Result = Struct.new(:model, :attributes, :checked, :plaintext, :rewritten, :skipped, keyword_init: true) do
    def line(write)
      return "#{model}: skipped (#{skipped})" if skipped

      "#{model}: #{checked} rows checked, #{plaintext} with plaintext #{attributes.join('/')}, " \
        "#{write ? "#{rewritten} encrypted" : 'nothing written (dry run)'}"
    end

    def status_line
      return "#{model}: skipped (#{skipped})" if skipped

      "#{model}: #{plaintext} plaintext of #{checked} rows (#{attributes.join('/')})"
    end
  end

  class << self
    # models: nil discovers every encrypting model; pass class names to limit the run.
    def call(write: false, tenant_id: nil, models: nil)
      targets(models).map { |target| new(target, write: write, tenant_id: tenant_id).run }
    end

    # Read-only: the same scan as a dry run.
    def status(tenant_id: nil, models: nil) = call(write: false, tenant_id: tenant_id, models: models)

    # Every concrete Active Record class that declares `encrypts`, sorted by name.
    def models
      eager_load!
      ActiveRecord::Base.descendants.select { |model| encrypting?(model) }.sort_by(&:name)
    end

    def targets(names = nil)
      list = names ? names.map { |name| name.is_a?(Class) ? name : name.constantize } : models
      list.filter_map { |model| target_for(model) }
    end

    # Where the last all-tenant status is kept for System → Health.
    def status_path = Pathname(ENV.fetch('RUPERT_ENCRYPTION_STATUS_FILE', Rails.root.join('storage/ops/encryption_status.json').to_s))

    def write_status!(results, at: Time.current)
      path = status_path
      path.dirname.mkpath
      payload = { at: at.iso8601, plaintext: results.sum(&:plaintext), models: results.count { |result| !result.skipped },
                  skipped: results.filter_map { |result| result.model if result.skipped } }
      tmp = path.sub_ext('.tmp')
      tmp.write(JSON.generate(payload))
      tmp.rename(path)
      payload
    end

    # The last recorded status, or nil when the task has never run (or the file cannot be read).
    def last_status
      data = JSON.parse(status_path.read)
      { at: Time.zone.parse(data['at'].to_s), plaintext: data['plaintext'].to_i, models: data['models'].to_i,
        skipped: Array(data['skipped']) }
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, Errno::EISDIR, JSON::ParserError, TypeError, ArgumentError
      nil
    end

    private

    # Loads every model file: app/models, app/modules and those of any engine that is loaded (Buzz).
    # app/modules is an autoload path that Rails excludes from eager loading, so its files are loaded one by one.
    def eager_load!
      Rails.application.eager_load!
      loader = Rails.autoloaders.main
      loader.dirs.grep(%r{/app/(models|modules)\z}).each do |dir|
        Dir.glob(File.join(dir, '**', '*.rb')).each do |file|
          loader.load_file(file)
        rescue Zeitwerk::Error
          next # a concern directory or an ignored file: not a model
        end
      end
    end

    def encrypting?(model)
      model.name.present? && !model.abstract_class? && own_attributes(model).any?
    end

    # The attributes whose type on this class is an encrypted one. Under STI, Rails shares one Set of names
    # between parent and child, so the type, not the Set, says which class really encrypts a column; a child
    # contributes only the columns its parent does not already encrypt (the parent's scan covers the rest).
    def own_attributes(model)
      declared = Array(model.encrypted_attributes).map(&:to_s)
      return declared unless model.table_exists? # reported as skipped; its types cannot be read without a table

      names = declared.select { |name| encrypted_type?(model, name) }
      parent = model.superclass
      return names unless parent < ActiveRecord::Base && !parent.abstract_class? && parent.table_name == model.table_name

      names.reject { |name| encrypted_type?(parent, name) }
    end

    def encrypted_type?(model, name)
      model.type_for_attribute(name).is_a?(ActiveRecord::Encryption::EncryptedAttributeType)
    rescue StandardError
      false
    end

    def target_for(model)
      attributes = own_attributes(model)
      return if attributes.empty?
      return Target.new(model: model, attributes: attributes, skipped: "table #{model.table_name} is missing") unless model.table_exists?
      return Target.new(model: model, attributes: attributes, skipped: 'no primary key') if model.primary_key.blank?

      columns = model.column_names
      missing = attributes - columns
      shared = attributes - shared_safe(model, attributes)
      notes = []
      notes << "column #{missing.join('/')} missing" if missing.any?
      notes << "#{shared.join('/')} not encrypted by every model on #{model.table_name}" if shared.any?
      kept = attributes - missing - shared
      Target.new(model: model, attributes: kept, skipped: kept.empty? ? notes.join('; ') : nil)
    end

    # When unrelated classes share one table (the tasks table serves several kinds), a column is rewritten
    # only if every one of them decrypts it, so no class is left reading ciphertext it does not expect.
    def shared_safe(model, attributes)
      others = ActiveRecord::Base.descendants.select do |other|
        other != model && other.name.present? && !other.abstract_class? && other.table_name == model.table_name &&
          other.base_class != model.base_class
      end
      attributes.select { |name| others.all? { |other| encrypted_type?(other, name) } }
    end
  end

  def initialize(target, write:, tenant_id:)
    @model = target.model
    @attributes = target.attributes
    @skipped = target.skipped
    @write = write
    @tenant_id = tenant_id.presence
  end

  def run
    result = Result.new(model: @model.name, attributes: @attributes, checked: 0, plaintext: 0, rewritten: 0, skipped: @skipped)
    return result if @skipped
    return result.tap { result.skipped = 'no tenant_id column' } if @tenant_id && !@model.column_names.include?('tenant_id')

    types = @attributes.index_with { |name| @model.type_for_attribute(name) }
    scope.in_batches(of: batch_size) do |batch|
      rows = @model.connection.select_rows(batch.select(@model.primary_key, *@attributes).to_sql)
      pending = rows.filter_map do |id, *raws|
        plain = @attributes.zip(raws).reject { |name, raw| raw.nil? || ciphertext?(types[name], raw) }
        [id, plain] if plain.any?
      end
      result.checked += rows.size
      result.plaintext += pending.size
      next unless @write && pending.any?

      @model.transaction { pending.each { |id, plain| result.rewritten += rewrite(id, plain, types) } }
    end
    result
  end

  private

  # Every row of the model, across tenants unless one is named; default scopes (tenant, merged profiles) are lifted.
  # STI subclasses keep their type condition.
  def scope
    rows = @model.unscoped
    @tenant_id ? rows.where(tenant_id: @tenant_id) : rows
  end

  def batch_size
    return BATCH_FOR[@model.name] if BATCH_FOR.key?(@model.name)

    columns = @model.columns_hash
    return BLOB_BATCH if @attributes.any? { |name| columns[name]&.type == :binary || name.match?(BLOB_COLUMN) }
    return DOCUMENT_BATCH if @attributes.any? { |name| name.match?(DOCUMENT_COLUMN) }

    BATCH
  end

  # A value stored before the column was encrypted may still carry its old SQLite storage class (an integer
  # or real for amount columns); only a string can be ciphertext.
  def ciphertext?(type, raw) = raw.is_a?(String) && type.encrypted?(raw)

  # The legacy plaintext values, read back through their types, written through the encrypted types.
  def rewrite(id, plain, types)
    values = plain.to_h { |name, raw| [name, types[name].deserialize(raw.is_a?(String) ? raw : raw.to_s)] }
    @model.unscoped.where(@model.primary_key => id).update_all(values)
  end
end
