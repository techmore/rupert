# frozen_string_literal: true

module Finance
  # A 1099 as issued (#472): the payee's form, box and total at that moment, and who issued it. Issuing a tax year
  # records an original per payee; a later change to the totals is issued as a corrected form, recorded as a new row.
  # Rows are never changed or removed, so the history of what each recipient was sent stays intact.
  class TaxFormFiling < ApplicationRecord
    include TenantScoped

    self.table_name = 'tax_form_filings'

    KINDS = %w[original corrected].freeze

    # The recipient's name and TIN digits as issued are encrypted at rest (#421).
    encrypts :legal_name, :tin_last4

    belongs_to :tax_payee, class_name: 'Finance::TaxPayee'

    validates :kind, inclusion: { in: KINDS }
    validates :tax_year, numericality: { only_integer: true, greater_than_or_equal_to: 2000 }
    validates :form_type, inclusion: { in: %w[nec misc] }
    validates :paid_cents, numericality: { only_integer: true }
    validates :legal_name, :issued_at, presence: true
    validate :payee_in_tenant, on: :create

    scope :for_year, ->(year) { where(tax_year: year.to_i) }

    # Issued forms are a record of what was sent: never edited or removed.
    def readonly? = persisted? || super

    def corrected? = kind == 'corrected'

    # A snapshot of a totals row (Finance::Form1099Totals::Row).
    def self.issue!(row, year:, kind:, by: Current.user)
      payee = row.payee
      create!(tax_payee: payee, tax_year: year.to_i, kind: kind, form_type: payee.form_type, misc_box: payee.misc_box,
        paid_cents: row.paid_cents, legal_name: payee.legal_name, tin_last4: payee.tin_last4, issued_by_id: by&.id,
        issued_by_name: by&.display_name.presence || by&.email, issued_at: Time.current)
    end

    # Whether the form as issued no longer matches the recomputed row.
    def differs_from?(row)
      row.paid_cents != paid_cents || row.payee.form_type != form_type || row.payee.misc_box.to_s != misc_box.to_s
    end

    def form_label = form_type == 'misc' ? "#{TaxPayee::FORMS['misc']} · #{TaxPayee::MISC_BOXES[misc_box]}" : TaxPayee::FORMS[form_type]

    private

    def payee_in_tenant
      errors.add(:tax_payee, 'is not in this workspace') if tax_payee && tax_payee.tenant_id != tenant_id
    end
  end
end
