# frozen_string_literal: true

require 'digest'

# Reads Square Loyalty with read endpoints only (LOYALTY_READ): the token status,
# the program, its promotions, the member accounts and the points ledger. POST
# here is Square's search verb; no create, adjust, accumulate, redeem or cancel
# endpoint is ever called.
class SquareLoyaltyReader
  class Error < SquareClient::Error
    def initialize(message, reason: :response)
      super
    end
  end

  # The connection is fine but was not granted LOYALTY_READ.
  class MissingScope < Error
    MESSAGE = 'The Square connection cannot read Loyalty: its access token lacks the LOYALTY_READ permission. ' \
              'In the Square Developer Dashboard, re-authorize the Rupert app with LOYALTY_READ added to its OAuth scopes ' \
              '(or use a personal access token from that app), save the new token under Square in Connections, then sync again.'

    def initialize(message = MESSAGE)
      super(message, reason: :forbidden)
    end
  end

  REQUIRED_SCOPE = 'LOYALTY_READ'
  ID = /\A[a-zA-Z0-9_:-]{1,255}\z/
  ACCOUNT_PAGE = 200 # Square's maximum for SearchLoyaltyAccounts
  EVENT_PAGE = 30 # Square's maximum for SearchLoyaltyEvents
  PROMOTION_PAGE = 30
  MAX_ACCOUNTS = 200_000

  attr_reader :fingerprint, :merchant_id, :scope_status

  def self.credential_fingerprint
    Digest::SHA256.hexdigest([Current.tenant_id, SquareClient.environment, SquareClient.token].join("\0"))
  end

  def initialize(read_seconds: 600)
    @read_seconds = read_seconds
  end

  # Confirms LOYALTY_READ before any loyalty read. Personal access tokens may report
  # no scope list; then the loyalty endpoints themselves decide (403 => MissingScope).
  def check_access!
    raise Error.new('Configure the Square connection first.', reason: :invalid) unless SquareClient.configured?

    @fingerprint = self.class.credential_fingerprint
    document = SquareClient.request('/oauth2/token/status', method: 'POST', body: {})
    scopes = document['scopes']
    @merchant_id = document['merchant_id'] if document['merchant_id'].is_a?(String) && document['merchant_id'].match?(ID)
    raise MissingScope if scopes.is_a?(Array) && !scopes.include?(REQUIRED_SCOPE)

    @scope_status = scopes.is_a?(Array) ? 'granted' : 'unreported'
  rescue MissingScope
    raise
  rescue SquareClient::Error => e
    raise Error.new('Square rejected the saved access token. Reconnect Square, then sync again.', reason: :unauthorized) if e.status == 401

    # Token status is advisory; the loyalty reads below still enforce access.
    @scope_status = 'unreported'
  end

  # The seller's program, or nil when the seller has no loyalty program.
  def program
    document = SquareClient.request('/loyalty/programs/main')
    row = document['program']
    raise Error, 'Square returned an unreadable loyalty program. Previous loyalty data was kept.' unless row.is_a?(Hash) && valid_id?(row['id'])

    row
  rescue SquareClient::Error => e
    return nil if e.status == 404 && !e.is_a?(Error)

    raise translate(e)
  end

  def promotions(program_id)
    raise Error, 'Square returned an invalid loyalty program ID.' unless valid_id?(program_id)

    rows = []
    paginate('loyalty_promotions', deadline: deadline_from_now) do |cursor|
      query = { limit: PROMOTION_PAGE }
      query[:cursor] = cursor if cursor
      SquareClient.request("/loyalty/programs/#{program_id}/promotions?#{query.to_query}")
    end.each { |page| rows.concat(page) }
    unique!(rows, 'promotions')
  end

  # Every member account; a complete read or an error, never a partial list.
  def accounts
    rows = []
    paginate('loyalty_accounts', deadline: deadline_from_now) do |cursor|
      body = { limit: ACCOUNT_PAGE }
      body[:cursor] = cursor if cursor
      SquareClient.request('/loyalty/accounts/search', method: 'POST', body: body)
    end.each do |page|
      rows.concat(page)
      raise Error.new('Square returned more loyalty members than Rupert reads at once. Previous loyalty data was kept.', reason: :limit) if rows.size > MAX_ACCOUNTS
    end
    unique!(rows, 'members')
  end

  # Ledger pages newest first within [start_at, end_at). Yields each page and returns
  # [:complete, nil] or, when the time budget runs out, [:partial, oldest_created_at]
  # so the caller can resume below that point next time.
  def each_event_page(start_at: nil, end_at: nil, deadline: deadline_from_now, max_pages: 10_000)
    range = {}
    range[:start_at] = start_at.utc.iso8601 if start_at
    range[:end_at] = end_at.utc.iso8601 if end_at
    oldest = nil
    outcome = paginate('events', deadline: deadline, partial: true, max_pages: max_pages) do |cursor|
      body = { limit: EVENT_PAGE }
      body[:query] = { filter: { date_time_filter: { created_at: range } } } if range.any?
      body[:cursor] = cursor if cursor
      SquareClient.request('/loyalty/events/search', method: 'POST', body: body)
    end
    outcome.each do |page|
      page.each do |row|
        at = timestamp(row['created_at'])
        oldest = at if at && (oldest.nil? || at < oldest)
      end
      yield page
    end
    outcome.complete? ? [:complete, nil] : [:partial, oldest]
  end

  def deadline_from_now(seconds = @read_seconds)
    Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
  end

  def verify_connection!
    EnvStore.clear_cache!
    raise Error.new('The Square connection changed during the read. Previous loyalty data was kept.', reason: :changed) unless fingerprint == self.class.credential_fingerprint
  end

  def timestamp(value)
    return unless value.is_a?(String) && value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)

    Time.iso8601(value)
  rescue ArgumentError
    nil
  end

  def valid_id?(id)
    id.is_a?(String) && id.match?(ID)
  end

  private

  # Lazily walks a cursor. Rejects errors, malformed rows, repeated cursors and
  # empty pages that still carry a cursor. With partial: true, running out of
  # time ends the walk early and Pages#complete? is false.
  class Pages
    include Enumerable

    def initialize(reader, key, deadline, partial, max_pages, fetch)
      @reader, @key, @deadline, @partial, @max_pages, @fetch = reader, key, deadline, partial, max_pages, fetch
      @complete = false
    end

    def complete? = @complete

    def each
      seen = {}
      cursor = nil
      @max_pages.times do
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > @deadline
          return if @partial

          raise Error.new('The Square loyalty read took too long. Previous loyalty data was kept.', reason: :limit)
        end
        document = @fetch.call(cursor)
        page = document.is_a?(Hash) ? document.fetch(@key, []) : nil
        unless document.is_a?(Hash) && document['errors'].blank? && page.is_a?(Array) && page.all? { |row| row.is_a?(Hash) && @reader.valid_id?(row['id']) }
          raise Error, 'Square returned incomplete loyalty data. Previous loyalty data was kept.'
        end

        yield page
        cursor = document['cursor']
        if cursor.nil? || cursor == ''
          @complete = true
          return
        end
        raise Error, 'Square loyalty pagination was incomplete. Previous loyalty data was kept.' unless cursor.is_a?(String) && cursor.bytesize.between?(1, 4096) && !seen[cursor] && page.any?

        seen[cursor] = true
      end
      raise Error.new('Square loyalty pagination exceeded its limit. Previous loyalty data was kept.', reason: :limit) unless @partial
    end
  end

  def paginate(key, deadline:, partial: false, max_pages: 2_000, &fetch)
    Pages.new(self, key, deadline, partial, max_pages, ->(cursor) { request(fetch, cursor) })
  end

  def request(fetch, cursor)
    fetch.call(cursor)
  rescue SquareClient::Error => e
    raise translate(e)
  end

  def translate(error)
    return error if error.is_a?(Error)
    return MissingScope.new if error.status == 403 || error.codes.include?('INSUFFICIENT_SCOPES')
    return Error.new('Square rejected the saved access token. Reconnect Square, then sync again.', reason: :unauthorized) if error.status == 401

    Error.new('Square loyalty data could not be read. Previous loyalty data was kept.', reason: error.reason || :response)
  end

  def unique!(rows, what)
    raise Error, "Square returned repeated loyalty #{what}. Previous loyalty data was kept." unless rows.map { |row| row['id'] }.uniq.size == rows.size

    rows
  end
end
