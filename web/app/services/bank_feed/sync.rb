# frozen_string_literal: true

require 'bigdecimal'
require 'digest'

module BankFeed
  class Sync
    Error = PlaidClient::Error

    def self.call(connection) = new(connection).call

    def initialize(connection)
      @connection = connection
      @client = connection.client
    end

    def call
      unless @connection.tenant_id == Current.tenant_id && Current.tenant&.status == 'active'
        raise Error.new('WORKSPACE_MISMATCH')
      end
      # The row lock serializes manual sync, scheduled sync and disconnect.
      # All pages, evidence, lines and the cursor commit together or not at all.
      @connection.with_lock do
        return unless @connection.connected? && @connection.sync_enabled?

        pages = fetch_pages
        pages.each { |page| apply_page(page) }
        @connection.update!(cursor: pages.last.fetch('next_cursor'), last_synced_at: Time.current, last_error_code: nil)
      end
    rescue Error => error
      @connection.update!(last_error_code: error.code) if @connection.tenant_id == Current.tenant_id && Current.tenant&.status == 'active'
      raise
    end

    private

    def fetch_pages
      attempts = 0
      begin
        cursor = @connection.cursor
        pages = []
        loop do
          raise Error.new('SYNC_TOO_LARGE') if pages.size >= 100
          page = @client.call('transactions/sync', access_token: @connection.access_token, cursor: cursor, count: 500)
          unless %w[added modified removed accounts].all? { |key| page[key].is_a?(Array) } &&
              page['next_cursor'].is_a?(String) && [true, false].include?(page['has_more'])
            raise Error.new('INVALID_RESPONSE')
          end
          pages << page
          break unless page['has_more']
          raise Error.new('INVALID_RESPONSE') if page['next_cursor'] == cursor
          cursor = page['next_cursor']
        end
        pages
      rescue Error => error
        attempts += 1
        retry if error.code == 'TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION' && attempts < 3
        raise
      end
    end

    def apply_page(page)
      accounts = page.fetch('accounts').index_by { |account| account.fetch('account_id') }
      transactions = (page.fetch('added') + page.fetch('modified')).map { |raw| normalize(raw, accounts) }
      # Keep source revisions as encrypted evidence, including removals. Group
      # by year to respect the evidence period limit even for older corrections.
      documents = transactions.group_by { |row| Date.iso8601(row.fetch('date')).year }.transform_values do |rows|
        dates = rows.map { |row| Date.iso8601(row.fetch('date')) }
        ReconciliationEvidence.retain!(bytes: { transactions: rows }.to_json, filename: "wells-fargo-#{@connection.environment}-feed.json", source: 'bank',
          kind: 'bank_statement', from: dates.min.iso8601, to: dates.max.iso8601,
          metadata: { provider: 'plaid', connection_id: @connection.id, environment: @connection.environment })
      end
      transactions.each { |row| upsert(row, documents.fetch(Date.iso8601(row.fetch('date')).year)) }
      page.fetch('removed').each { |row| remove(row.fetch('transaction_id')) }
    rescue KeyError, Date::Error, TypeError, ArgumentError
      raise Error.new('INVALID_RESPONSE')
    end

    def normalize(raw, accounts)
      account = accounts.fetch(raw.fetch('account_id'))
      unless account['type'] == 'depository' && %w[checking savings].include?(account['subtype'])
        raise Error.new('UNSUPPORTED_ACCOUNT')
      end
      raise Error.new('UNSUPPORTED_CURRENCY') unless raw['iso_currency_code'] == 'USD' && raw['unofficial_currency_code'].nil?
      raise Error.new('INVALID_RESPONSE') unless [true, false].include?(raw['pending'])
      amount = BigDecimal(raw.fetch('amount').to_s) * -100
      raise Error.new('INVALID_AMOUNT') unless amount.finite? && amount.frac.zero? && amount.abs < 10**15
      date = Date.iso8601(raw.fetch('date'))
      {
        'transaction_id' => raw.fetch('transaction_id'), 'account_id' => raw.fetch('account_id'),
        'date' => date.iso8601, 'amount_cents' => amount.to_i, 'pending' => raw.fetch('pending'),
        'description' => raw.fetch('name').to_s.squish.first(300).presence || '(no description)',
        # Never use a full bank account number or untrusted account name as a label.
        'account_label' => "#{@connection.environment == 'sandbox' ? 'Sandbox ' : ''}Wells Fargo #{account.fetch('subtype')} #{Digest::SHA256.hexdigest(raw.fetch('account_id')).first(6)}"
      }
    end

    def source_key(id)
      raise Error.new('INVALID_RESPONSE') unless id.is_a?(String) && id.present? && id.bytesize <= 256
      Digest::SHA256.hexdigest([@connection.item_id, id].to_json)
    end

    def upsert(row, document)
      entry = BankFeedEntry.find_or_initialize_by(bank_connection: @connection, source_key: source_key(row.fetch('transaction_id')))
      previous = entry.payload
      return if entry.persisted? && previous == row && entry.source_state == 'active'

      entry.payload_json = row.to_json
      entry.source_state = 'active'
      line = entry.bank_statement_line
      line.lock! if line
      if row['pending'] || row['amount_cents'].zero?
        retire_line(line) if line
      elsif line
        if (line.status == 'pending' && line.source_state == 'active') ||
            (line.status == 'ignored' && line.source_state == 'removed' && line.decided_by_name == 'Bank feed: removed before review')
          line.update!(posted_on: row['date'], description: row['description'], amount_cents: row['amount_cents'], document_id: document.id,
            source_state: 'active', status: 'pending', decided_by_id: nil, decided_by_name: nil, decided_at: nil)
        elsif previous != row || line.source_state != 'active'
          line.update!(source_state: 'changed')
        end
      else
        line = BankStatementLine.create!(document_id: document.id, account_label: row['account_label'], line_no: BankStatementLine.where(document_id: document.id).count + 1,
          posted_on: row['date'], description: row['description'], amount_cents: row['amount_cents'],
          fingerprint: Digest::SHA256.hexdigest(['plaid', @connection.id, entry.source_key].to_json))
        entry.bank_statement_line = line
      end
      entry.save!
    end

    def retire_line(line)
      attrs = { source_state: 'removed' }
      if line.status == 'pending'
        attrs.merge!(status: 'ignored', decided_by_name: 'Bank feed: removed before review', decided_at: Time.current)
      end
      line.update!(attrs)
    end

    def remove(id)
      entry = BankFeedEntry.find_by(bank_connection: @connection, source_key: source_key(id))
      return unless entry && entry.source_state != 'removed'
      row = entry.payload
      date = Date.iso8601(row.fetch('date'))
      ReconciliationEvidence.retain!(bytes: { removed: row }.to_json, filename: 'wells-fargo-removal.json', source: 'bank', kind: 'bank_statement',
        from: date.iso8601, to: date.iso8601, metadata: { provider: 'plaid', connection_id: @connection.id, environment: @connection.environment })
      if (line = entry.bank_statement_line)
        line.lock!
        retire_line(line)
      end
      entry.update!(source_state: 'removed')
    end
  end
end
