# frozen_string_literal: true

# A lab certificate of analysis (COA) for an approved product and, optionally,
# one batch (F70; the library itself is #549). Rupert keeps the link to the
# original document; it never infers legal status or card eligibility from it.
# Withdrawn certificates stay for history and are never current.
class CertificateOfAnalysis < ApplicationRecord
  include TenantScoped
  self.table_name = 'certificates_of_analysis'

  belongs_to :compliance_catalog_item

  normalizes :batch, :lab_name, :report_identifier, :document_url, with: ->(value) { value.to_s.strip.presence }

  validates :lab_name, presence: true, length: { maximum: 120 }
  validates :batch, :report_identifier, length: { maximum: 120 }
  validates :tested_on, presence: true
  validates :status, inclusion: { in: %w[current withdrawn] }
  validates :document_url, presence: true, length: { maximum: 2000 }
  validate do
    uri = begin
      URI.parse(document_url.to_s)
    rescue URI::InvalidURIError
      nil
    end
    errors.add(:document_url, 'must be an https link to the lab report') unless uri.is_a?(URI::HTTPS) && uri.host.present?
    errors.add(:tested_on, 'cannot be in the future') if tested_on && tested_on > Date.current
    errors.add(:expires_on, 'must be after the test date') if tested_on && expires_on && expires_on < tested_on
    errors.add(:base, 'Certificate belongs to another workspace.') if compliance_catalog_item && compliance_catalog_item.tenant_id != tenant_id
  end

  def withdrawn? = status == 'withdrawn'

  def current_on?(day, max_age_days: CompliancePolicy::DEFAULT_COA_MAX_AGE_DAYS)
    return false if withdrawn? || tested_on.nil? || tested_on > day
    return false if expires_on && expires_on < day

    tested_on >= day - max_age_days
  end

  # The day it stops being current under the policy's age limit or its own expiry.
  def current_until(max_age_days: CompliancePolicy::DEFAULT_COA_MAX_AGE_DAYS)
    [expires_on, tested_on + max_age_days].compact.min
  end

  def label = [lab_name, report_identifier, (batch && "batch #{batch}")].compact.join(' · ')
end
