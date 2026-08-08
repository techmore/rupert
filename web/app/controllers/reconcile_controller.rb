# frozen_string_literal: true

class ReconcileController < AuthenticatedController
  def index
    @rows = Reconciler.build_rows
    @summary = Reconciler.summary(@rows)
  end

  def policy
    sku = params[:sku].to_s
    priority = params[:priority].to_s
    unless Reconciler::PRIORITIES.include?(priority)
      return redirect_to(reconcile_index_path, alert: "Unknown priority")
    end

    InventoryPolicy.set!(sku, priority) if sku.present?
    redirect_to reconcile_index_path, notice: "Priority updated for #{sku}"
  end

  def apply
    @result = PlanApplier.apply!(skus: params[:skus].presence)
    redirect_to reconcile_index_path, notice: "Applied #{@result[:applied]} adjustment(s)"
  rescue PlanApplier::SafetyLocked, StandardError => e
    redirect_to reconcile_index_path, alert: e.message
  end
end
