# frozen_string_literal: true

module Finance
  # The year-end lock for 1099s (#472). Once forms are issued for a tax year, the totals on them are kept as
  # Finance::TaxFormFiling rows. Recomputed totals that no longer match (a late payment, an edited expense, a changed
  # form or box) show as a difference that needs a corrected form; payees who reach the threshold later need an
  # original. Issued rows are never changed.
  class Form1099Lock
    Entry = Struct.new(:row, :filing, :state, keyword_init: true) do
      # Recomputed total minus the total on the latest form issued.
      def difference_cents = filing ? row.paid_cents - filing.paid_cents : nil
    end

    attr_reader :year, :totals

    def initialize(totals)
      @totals = totals
      @year = totals.year
      @filings = Finance::TaxFormFiling.for_year(year).order(:issued_at, :id).to_a
      @latest = @filings.group_by(&:tax_payee_id).transform_values(&:last)
    end

    def issued? = @filings.any?
    def first_issue = @filings.first
    def history(payee) = @filings.select { |filing| filing.tax_payee_id == payee.id }
    def latest(payee) = @latest[payee.id]

    # One entry per payee: 'issued' (matches), 'changed' (needs a corrected form), 'not_issued' (needs an original) or
    # nil (no form needed and none issued).
    def entry(row)
      filing = latest(row.payee)
      state =
        if filing then filing.differs_from?(row) ? 'changed' : 'issued'
        elsif row.status(year) == 'needed' then 'not_issued'
        end
      Entry.new(row: row, filing: filing, state: state)
    end

    def entries = @entries ||= totals.rows.map { |row| entry(row) }
    def changed = entries.select { |entry| entry.state == 'changed' }
    def not_issued = entries.select { |entry| entry.state == 'not_issued' }

    # Records an original for every payee who needs a 1099 and has none yet this year.
    def issue!(by: Current.user)
      Finance::TaxFormFiling.transaction do
        not_issued.map { |entry| Finance::TaxFormFiling.issue!(entry.row, year: year, kind: 'original', by: by) }
      end
    end

    # Records a corrected form for the payee from the recomputed totals. Nil unless the totals changed.
    def correct!(payee, by: Current.user)
      entry = entries.find { |candidate| candidate.row.payee.id == payee.id }
      return unless entry&.state == 'changed'

      Finance::TaxFormFiling.issue!(entry.row, year: year, kind: 'corrected', by: by)
    end
  end
end
