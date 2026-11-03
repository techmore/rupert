# frozen_string_literal: true

module Compliance
  # Approved product categories and whether the card processor accepts them.
  class CategoriesController < AuthenticatedController
    include ComplianceAccess

    before_action :require_compliance_editor!

    def create
      save(ComplianceCategory.new, 'added')
    end

    def update
      save(ComplianceCategory.find(params[:id]), 'saved')
    end

    private

    def save(category, verb)
      before = category.persisted? ? category.audit_snapshot : nil
      saved = ComplianceCategory.transaction do
        next false unless category.update(params.require(:compliance_category).permit(:name, :card_eligible, :prohibited, :notes))

        ComplianceEvent.record!('category_saved', subject: category, details: { 'before' => before, 'after' => category.audit_snapshot }.compact)
        true
      end
      if saved
        redirect_to compliance_path(tab: 'categories', location_id: params[:location_id]), notice: "Category #{category.name} #{verb}."
      else
        redirect_to compliance_path(tab: 'categories', location_id: params[:location_id]), alert: category.errors.full_messages.to_sentence
      end
    end
  end
end
