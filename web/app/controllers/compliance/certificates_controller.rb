# frozen_string_literal: true

module Compliance
  # Linking a lab certificate (COA) to an approved product or batch, and
  # withdrawing one. Withdrawn certificates stay in the history.
  class CertificatesController < AuthenticatedController
    include ComplianceAccess

    before_action :require_compliance_editor!
    before_action { @item = ComplianceCatalogItem.find(params[:catalog_item_id]) }

    def new
      @certificate = @item.certificates_of_analysis.new(tested_on: Date.current)
    end

    def create
      @certificate = @item.certificates_of_analysis.new(params.require(:certificate_of_analysis)
        .permit(:batch, :lab_name, :report_identifier, :tested_on, :expires_on, :document_url).merge(added_by_id: Current.user.id))
      saved = CertificateOfAnalysis.transaction do
        next false unless @certificate.save

        ComplianceEvent.record!('coa_added', subject: @certificate, location_id: @item.location_id,
          details: { 'item' => @item.compliant_name, 'tested_on' => @certificate.tested_on.iso8601, 'expires_on' => @certificate.expires_on&.iso8601 })
        true
      end
      return render(:new, status: :unprocessable_entity) unless saved

      redirect_to edit_compliance_catalog_item_path(@item), notice: 'Certificate linked.'
    end

    def withdraw
      certificate = @item.certificates_of_analysis.find(params[:id])
      reason = params[:reason].to_s.squish
      return redirect_to(edit_compliance_catalog_item_path(@item), alert: 'Give a reason of at least 8 characters.') if reason.length < 8

      CertificateOfAnalysis.transaction do
        certificate.update!(status: 'withdrawn', withdrawn_by_id: Current.user.id, withdrawn_at: Time.current, withdrawal_reason: reason)
        ComplianceEvent.record!('coa_withdrawn', subject: certificate, location_id: @item.location_id, reason: reason)
      end
      redirect_to edit_compliance_catalog_item_path(@item), notice: 'Certificate withdrawn. It is no longer current.'
    end
  end
end
