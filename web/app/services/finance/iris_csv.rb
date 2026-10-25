# frozen_string_literal: true

require 'csv'

module Finance
  # The 1099-NEC and 1099-MISC filing files for the IRS Information Returns Intake System (IRIS) Taxpayer Portal
  # "Upload CSV with Form Data" (#472). One file per form type, built from the forms as issued (Finance::TaxFormFiling)
  # and generated in memory only: it carries full TINs, so it is never written to disk or storage.
  #
  # The columns, their order and the value formats follow the IRS "Template Formatting Guidelines" for tax year 2025
  # (https://www.irs.gov/pub/irs-efile/ty2025-template-formatting-guidelines.zip, updated January 14, 2026, linked from
  # https://www.irs.gov/filing/e-file-information-returns-with-iris). The header text is the field name the guidelines
  # give for each column (an asterisk marks a required field there). The template file itself is only downloadable
  # from inside the IRIS Taxpayer Portal, so its header row could not be compared byte for byte: check it against a
  # freshly downloaded template before the first upload.
  #
  # IRIS takes corrections only through "Make a Correction" in the portal (Publication 5717, 3.6.7), and the CSV
  # template has no corrected-return column. So the file holds each payee's original form; corrected forms are listed
  # separately (#corrections) for the person filing to enter in the portal.
  class IrisCsv
    TEMPLATE_YEAR = 2025
    GUIDELINES_URL = 'https://www.irs.gov/pub/irs-efile/ty2025-template-formatting-guidelines.zip'
    MAX_RECORDS = 250 # per file (Publication 5717, 3.5)

    PAYER = ['Form Type', 'Tax Year', 'Payer TIN Type*', 'Payer Taxpayer ID Number*', 'Payer Name Type*',
             'Payer Business or Entity Name Line 1', 'Payer Business or Entity Name Line 2', 'Payer First Name',
             'Payer Middle Name', 'Payer Last Name (Surname)', 'Payer Suffix', 'Payer Country*', 'Payer Address Line 1*',
             'Payer Address Line 2', 'Payer City/Town*', 'Payer State/Province/Territory*', 'Payer ZIP/Postal Code*',
             'Payer Phone Type', 'Payer Phone'].freeze
    RECIPIENT = ['Recipient TIN Type', 'Recipient Taxpayer ID Number', 'Recipient Name Type*',
                 'Recipient Business or Entity Name Line 1', 'Recipient Business or Entity Name Line 2', 'Recipient First Name',
                 'Recipient Middle Name', 'Recipient Last Name (Surname)', 'Recipient Suffix', 'Recipient Country*',
                 'Recipient Address Line 1*', 'Recipient Address Line 2', 'Recipient City/Town*',
                 'Recipient State/Province/Territory*', 'Recipient ZIP/Postal Code*', 'Office Code', 'Form Account Number'].freeze
    STATES = ['Combined Federal/State Filing (CF/SF)'] + [1, 2].flat_map do |n|
      ["State #{n}", "State #{n} - State Tax Withheld", "State #{n} - State/Payer state number", "State #{n} - State income",
       "State #{n} - Local income tax withheld", "State #{n} - Special Data Entries"]
    end.freeze

    COLUMNS = {
      'nec' => PAYER + RECIPIENT + ['2nd TIN Notice', 'Box 1 - Nonemployee Compensation',
                                    'Box 2 - Payer made direct sales totaling $5,000 or more of consumer products to a recipient for resale',
                                    'Box 3 - Excess golden parachute payments', 'Box 4 - Federal income tax withheld'] + STATES,
      'misc' => PAYER + RECIPIENT + ['FATCA Filing Requirements', '2nd TIN Notice', 'Box 1 - Rents', 'Box 2 - Royalties',
                                     'Box 3 - Other income', 'Box 4 - Federal income tax withheld', 'Box 5 - Fishing boat proceeds',
                                     'Box 6 - Medical and health care payments',
                                     'Box 7 - Direct sales of $5,000 or more of consumer products to a recipient for resale',
                                     'Box 8 - Substitute payments in lieu of dividends or interest', 'Box 9 - Crop insurance proceeds',
                                     'Box 10 - Gross proceeds paid to an attorney', 'Box 11 - Fish purchased for resale',
                                     'Box 12 - Section 409A deferrals', 'Box 15 - Nonqualified deferred compensation'] + STATES
    }.freeze
    FORM_NAMES = { 'nec' => '1099-NEC', 'misc' => '1099-MISC' }.freeze
    MISC_BOX_COLUMNS = { '1' => 'Box 1 - Rents', '2' => 'Box 2 - Royalties', '3' => 'Box 3 - Other income',
                         '6' => 'Box 6 - Medical and health care payments', '10' => 'Box 10 - Gross proceeds paid to an attorney' }.freeze
    TIN_TYPES = { 'ssn' => 'SSN', 'ein' => 'EIN', 'itin' => 'ITIN' }.freeze
    SUFFIXES = %w[JR SR II III IV V].freeze

    # Character rules from the guidelines: names allow letters, digits, space - # ( ) & '; addresses letters, digits,
    # space - /; cities letters and spaces; individual names letters, spaces and hyphens. Periods and commas are dropped
    # (IRIS rejects them in names and addresses); anything else outside the set becomes a space.
    NAME = /[^A-Za-z0-9 \-#()&']/
    NAME_LINE2 = %r{[^A-Za-z0-9 \-#()&'/%]}
    ADDRESS = %r{[^A-Za-z0-9 \-/]}
    CITY = /[^A-Za-z ]/
    PERSON = /[^A-Za-z -]/

    Correction = Struct.new(:filing, :previous, keyword_init: true) do
      # IRIS needs a 2-step correction when the form type changed: zero out the old form, file an original of the new.
      def two_step? = previous && previous.form_type != filing.form_type
    end

    attr_reader :year, :form_type, :problems

    def self.form_types = FORM_NAMES.keys

    def initialize(year:, form_type:, payer: Finance::TaxPayer.load)
      @year = year.to_i
      @form_type = form_type.to_s
      raise ArgumentError, "unknown form #{form_type}" unless FORM_NAMES.key?(@form_type)

      @payer = payer
      @filings = Finance::TaxFormFiling.for_year(@year).includes(:tax_payee).order(:issued_at, :id).to_a
      @problems = []
    end

    def form_name = FORM_NAMES.fetch(form_type)
    def columns = COLUMNS.fetch(form_type)
    def filename = "iris-#{form_name.downcase}-#{year}.csv"

    # Each payee's original form of this type for the year, in name order.
    def originals
      @originals ||= @filings.select { |filing| filing.kind == 'original' && filing.form_type == form_type }.sort_by(&:legal_name)
    end

    # Corrected forms of this type, with the form they replace: these go through "Make a Correction" in IRIS.
    def corrections
      @corrections ||= @filings.each_with_index.filter_map do |filing, index|
        next unless filing.corrected? && filing.form_type == form_type

        previous = @filings.first(index).select { |other| other.tax_payee_id == filing.tax_payee_id }.last
        Correction.new(filing: filing, previous: previous)
      end
    end

    # The CSV text, or nil when a record would not pass the IRIS checks (see #problems). Holds full TINs: send it, never
    # store or log it.
    def render
      @problems = []
      @problems << "More than #{MAX_RECORDS} forms: IRIS takes at most #{MAX_RECORDS} per file." if originals.size > MAX_RECORDS
      payer = payer_values
      rows = originals.map do |filing|
        values = payer.merge(recipient_values(filing))
        columns.map { |column| values[column] }
      end
      return if @problems.any?

      CSV.generate(row_sep: "\r\n") do |csv|
        csv << columns
        rows.each { |row| csv << row }
      end
    end

    private

    def payer_values
      phone = @payer.phone.to_s.gsub(/\D/, '').delete_prefix('1')
      phone = nil unless phone.length == 10
      { 'Form Type' => form_name, 'Tax Year' => year.to_s, 'Payer TIN Type*' => 'EIN', 'Payer Taxpayer ID Number*' => @payer.formatted_tin,
        'Payer Name Type*' => 'B', 'Payer Business or Entity Name Line 1' => text(@payer.name, NAME, 40, 'Payer name'),
        'Payer Country*' => 'US', 'Payer Address Line 1*' => text(@payer.street, ADDRESS, 35, 'Payer address'),
        'Payer City/Town*' => text(@payer.city, CITY, 40, 'Payer city'), 'Payer State/Province/Territory*' => @payer.state,
        'Payer ZIP/Postal Code*' => @payer.zip.to_s.delete('-'), 'Payer Phone Type' => ('D' if phone), 'Payer Phone' => phone }
    end

    def recipient_values(filing)
      payee = filing.tax_payee
      who = filing.legal_name
      tin = payee.tin.to_s
      @problems << "#{who}: no TIN on file." if tin.length != 9 || TIN_TYPES[payee.tin_type].nil?
      missing = { 'address' => payee.address_line1, 'city' => payee.city, 'state' => payee.state, 'ZIP code' => payee.postal_code }.select { |_, value| value.blank? }.keys
      @problems << "#{who}: no #{missing.to_sentence} on file." if missing.any?

      values = { 'Recipient TIN Type' => TIN_TYPES[payee.tin_type], 'Recipient Taxpayer ID Number' => formatted_tin(tin, payee.tin_type),
                 'Recipient Country*' => 'US', 'Recipient Address Line 1*' => text(payee.address_line1, ADDRESS, 35, "#{who}: address line 1"),
                 'Recipient Address Line 2' => text(payee.address_line2, ADDRESS, 35, "#{who}: address line 2"),
                 'Recipient City/Town*' => text(payee.city, CITY, 40, "#{who}: city"), 'Recipient State/Province/Territory*' => payee.state,
                 'Recipient ZIP/Postal Code*' => payee.postal_code.to_s.delete('-').presence, '2nd TIN Notice' => 'N' }
      values.merge!(recipient_name(filing, payee))
      values.merge!(amounts(filing))
    end

    # Individuals (SSN or ITIN) by first and last name, so IRS name matching works; everyone else by business name.
    def recipient_name(filing, payee)
      who = filing.legal_name
      return business_name(filing, payee) unless %w[ssn itin].include?(payee.tin_type)

      parts = clean(filing.legal_name, PERSON).split
      suffix = parts.pop if parts.size > 2 && SUFFIXES.include?(parts.last.upcase)
      if parts.size < 2
        @problems << "#{who}: an individual needs a first and last name."
        return {}
      end
      first, last = parts.first, parts.last
      middle = parts[1...-1].join(' ').presence
      { 'Recipient Name Type*' => 'I', 'Recipient First Name' => limit(first, 20, "#{who}: first name"),
        'Recipient Middle Name' => limit(middle, 20, "#{who}: middle name"), 'Recipient Last Name (Surname)' => limit(last, 20, "#{who}: last name"),
        'Recipient Suffix' => suffix }
    end

    def business_name(filing, payee)
      who = filing.legal_name
      line2 = payee.business_name if payee.business_name.present? && payee.business_name.strip.casecmp(filing.legal_name.strip) != 0
      { 'Recipient Name Type*' => 'B', 'Recipient Business or Entity Name Line 1' => text(filing.legal_name, NAME, 40, "#{who}: name"),
        'Recipient Business or Entity Name Line 2' => text(line2, NAME_LINE2, 40, "#{who}: business name") }
    end

    def amounts(filing)
      @problems << "#{filing.legal_name}: the amount issued is not above zero." unless filing.paid_cents.positive?
      amount = format('%.2f', filing.paid_cents / 100.0) if filing.paid_cents.positive?
      case form_type
      when 'nec' then { 'Box 1 - Nonemployee Compensation' => amount, 'Box 2 - Payer made direct sales totaling $5,000 or more of consumer products to a recipient for resale' => 'N' }
      else
        { 'FATCA Filing Requirements' => 'N', 'Box 7 - Direct sales of $5,000 or more of consumer products to a recipient for resale' => 'N',
          MISC_BOX_COLUMNS.fetch(filing.misc_box.to_s) => amount }
      end
    end

    def formatted_tin(tin, type)
      return if tin.length != 9

      type == 'ein' ? "#{tin[0, 2]}-#{tin[2..]}" : "#{tin[0, 3]}-#{tin[3, 2]}-#{tin[5..]}"
    end

    def text(value, disallowed, max, label) = limit(clean(value, disallowed), max, label)

    def limit(value, max, label)
      @problems << "#{label} is longer than #{max} characters." if value && value.length > max
      value
    end

    # Accents to plain letters, periods and commas dropped, other disallowed characters to spaces, single spaces only.
    def clean(value, disallowed)
      I18n.transliterate(value.to_s).delete('.,').gsub(disallowed, ' ').squeeze(' ').strip.sub(/\A[-\s]+/, '').presence
    end
  end
end
