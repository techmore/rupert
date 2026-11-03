# frozen_string_literal: true

module Compliance
  # A store's register rules: lock the register to the approved catalog.
  class PoliciesController < AuthenticatedController
    include ComplianceAccess

    before_action :require_compliance_editor!

    def update
      location = Location.find(params[:location_id])
      policy = CompliancePolicy.for(location)
      before = policy.slice('locked_catalog', 'coa_max_age_days')
      attrs = params.require(:compliance_policy).permit(:locked_catalog, :coa_max_age_days)
      if ActiveModel::Type::Boolean.new.cast(attrs[:locked_catalog]) && !ComplianceCatalogItem.approved.exists?(location_id: location.id)
        return redirect_to(compliance_path(location_id: location.id), alert: 'Approve at least one item before locking the register.')
      end

      saved = CompliancePolicy.transaction do
        next false unless policy.update(attrs.merge(updated_by_id: Current.user.id))

        ComplianceEvent.record!('policy_changed', subject: location, location_id: location.id,
          details: { 'before' => before, 'after' => policy.slice('locked_catalog', 'coa_max_age_days') })
        true
      end
      if saved
        redirect_to compliance_path(location_id: location.id), notice: policy.locked_catalog ? "#{location.name}’s register now sells approved items only." : "#{location.name}’s register is no longer locked."
      else
        redirect_to compliance_path(location_id: location.id), alert: policy.errors.full_messages.to_sentence
      end
    end
  end
end
